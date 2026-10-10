import Darwin
import Foundation

/// Serializes launch and cancellation. The owner waits for actual process exit.
final class CommandProcessLifecycle: @unchecked Sendable {
    private let process: Process
    private let requireOwnedProcessGroup: Bool
    private var ownedGroup: pid_t?
    private let onLaunch: (@Sendable (Int32) throws -> Void)?
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var cleanupFailed = false
    private var continuation: CheckedContinuation<Int32, any Error>?

    init(process: Process, requireOwnedProcessGroup: Bool = false, onLaunch: (@Sendable (Int32) throws -> Void)? = nil) {
        self.process = process
        self.requireOwnedProcessGroup = requireOwnedProcessGroup
        self.onLaunch = onLaunch
    }

    func run() async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                launch(continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func launch(_ continuation: CheckedContinuation<Int32, any Error>) {
        lock.lock()
        if cancelled {
            finished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        process.terminationHandler = { [weak self] process in
            self?.complete(status: process.terminationStatus)
        }
        do {
            try process.run()
            if requireOwnedProcessGroup {
                let pid = process.processIdentifier
                guard pid > 0, getpgid(pid) == pid, pid != getpgrp() else {
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.forceStopIfNeeded()
                    }
                    lock.unlock()
                    return
                }
                ownedGroup = pid
            }
            try onLaunch?(process.processIdentifier)
            lock.unlock()
        } catch {
            if process.isRunning { OwnedProcessTree.terminate(root: process.processIdentifier) }
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: BoundedCommandError.unavailable)
        }
    }

    private func complete(status: Int32) {
        lock.lock()
        finished = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        // Resuming under our lock can deadlock with Swift cancellation handlers.
        if cleanupFailed {
            pending?.resume(throwing: BoundedCommandError.cleanupUnverified)
        } else if requireOwnedProcessGroup && ownedGroup == nil {
            pending?.resume(throwing: BoundedCommandError.unavailable)
        } else { pending?.resume(returning: status) }
    }

    private func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        guard !finished, process.isRunning else { return }
        if let group = ownedGroup, getpgid(process.processIdentifier) == group, group != getpgrp() {
            // SwiftPM can put descendants in new groups. Parent/start identity,
            // not a group-wide assumption, determines which processes we stop.
            cleanupFailed = !OwnedProcessTree.terminate(root: process.processIdentifier)
            return
        }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.forceStopIfNeeded()
        }
    }

    private func forceStopIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, process.isRunning, process.processIdentifier > 0 else { return }
        // Only this directly owned process, never an unverified process group.
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
}
