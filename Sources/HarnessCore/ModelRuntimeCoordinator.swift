import Foundation

/// A local model server the coordinator can start and stop (Backburner's 27B, Strata's 125B MoE). It knows how to start,
/// stop and serve; when to start or stop it is the coordinator's decision alone, so no server stops another.
public protocol ModelRuntimeBackend: Sendable {
    /// Starts the server for `model` (nil: its default model), or returns at once when it already serves it.
    func start(model: String?) async throws
    /// Stops the server this App started (a server the user started elsewhere is left alone).
    func stop() async
}

/// One owner for the large local models (2026-10-25). The 27B and the 125B MoE do not fit in memory together, and before
/// this each server stopped the other when it started, so a 27B request could kill a 125B answer half-written. Now every
/// request holds a lease while it runs; a request for another model waits until every lease of the current one is returned,
/// and only then is the current server stopped and the next started. Requests are served in arrival order, so a stream of
/// requests for the current model cannot starve a waiting request for another one.
public actor ModelRuntimeCoordinator {
    public struct Target: Hashable, Sendable, CustomStringConvertible {
        /// nil: no model at all (memory freed for something else, e.g. the image model).
        public let backend: String?
        public let model: String?
        public init(backend: String?, model: String? = nil) { self.backend = backend; self.model = model }
        public static let none = Target(backend: nil)
        public var description: String { backend.map { "\($0):\(model ?? "default")" } ?? "none" }
    }

    public struct Lease: Hashable, Sendable {
        public let id: UUID
        public let target: Target
        /// Which start of the server this lease belongs to; a lease of an older generation is never served.
        public let generation: Int
    }

    private struct Waiter {
        let id: UUID
        let target: Target
        let continuation: CheckedContinuation<Lease, Error>
    }

    private let backends: [String: any ModelRuntimeBackend]
    public private(set) var current: Target = .none
    public private(set) var generation = 0
    private var switching = false
    private var leases: [UUID: Lease] = [:]
    private var queue: [Waiter] = []

    public init(backends: [String: any ModelRuntimeBackend]) { self.backends = backends }

    public var activeLeases: Int { leases.count }

    /// Waits until `target` is running and no other model holds the memory, then returns a lease for it. Cancelling the
    /// waiting task removes it from the queue. A start that fails is thrown to every request waiting for that target.
    public func acquire(_ target: Target) async throws -> Lease {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                queue.append(Waiter(id: id, target: target, continuation: continuation))
                pump()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    public func release(_ lease: Lease) {
        guard leases.removeValue(forKey: lease.id) != nil else { return }
        pump()
    }

    /// Runs `body` while holding a lease for `target`.
    public func withLease<T: Sendable>(_ target: Target, _ body: @Sendable () async throws -> T) async throws -> T {
        let lease = try await acquire(target)
        do { let value = try await body(); release(lease); return value } catch { release(lease); throw error }
    }

    /// Stops whatever runs, without waiting for leases (the App is quitting).
    public func shutdown() async {
        for backend in backends.values { await backend.stop() }
        current = .none
        generation += 1
        leases.removeAll()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).continuation.resume(throwing: CancellationError())
        pump()
    }

    /// Serves the queue head while it wants the current model; switches when the head wants another and no lease is out.
    private func pump() {
        while !switching, let head = queue.first {
            if head.target == current {
                queue.removeFirst()
                let lease = Lease(id: head.id, target: current, generation: generation)
                leases[lease.id] = lease
                head.continuation.resume(returning: lease)
            } else if leases.isEmpty {
                switching = true
                Task { await self.switchTo(head.target) }
                return
            } else {
                return
            }
        }
    }

    private func switchTo(_ target: Target) async {
        if let backend = current.backend, backend != target.backend || current.model != target.model {
            await backends[backend]?.stop()
        }
        current = .none
        generation += 1
        do {
            if let name = target.backend {
                guard let backend = backends[name] else { throw CoordinatorError.unknownBackend(name) }
                try await backend.start(model: target.model)
            }
            current = target
        } catch {
            // Everyone waiting for the target that failed hears why; requests for other targets stay queued.
            let failed = queue.filter { $0.target == target }
            queue.removeAll { $0.target == target }
            for waiter in failed { waiter.continuation.resume(throwing: error) }
        }
        switching = false
        pump()
    }

    public enum CoordinatorError: Error, Equatable { case unknownBackend(String) }
}
