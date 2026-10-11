import Foundation

public struct BoundedCommandResult: Codable, Sendable {
    public let exitCode: Int32
    public let output: String
    public let outputWasTruncated: Bool
    public let duration: TimeInterval

    /// The same result with terminal color codes removed from the output. Swift Build colors its diagnostics even when told
    /// not to (2026-10-11), and every parser here expects plain "file:line:col: error:" lines.
    public func withoutColorCodes() -> BoundedCommandResult {
        BoundedCommandResult(exitCode: exitCode,
                             output: output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression),
                             outputWasTruncated: outputWasTruncated, duration: duration)
    }
}

public enum BoundedCommandError: Error, Equatable, Sendable {
    case unavailable
    case timedOut
    case cleanupUnverified
}

public struct BoundedCommandRunner: Sendable {
    private let timeout: Duration
    private let maximumOutputBytes: Int

    public init(
        timeout: Duration = .seconds(180),
        maximumOutputBytes: Int = 40_000
    ) {
        self.timeout = timeout
        self.maximumOutputBytes = max(1, maximumOutputBytes)
    }

    /// `onOutput` is a best-effort progress stream, not an archival log.
    /// Observers must cooperate with task cancellation and avoid unbounded buffering.
    public func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String] = [:],
        inheritEnvironment: Bool = true,
        requireOwnedProcessGroup: Bool = false,
        onLaunch: (@Sendable (Int32) throws -> Void)? = nil,
        onOutput: (@Sendable (String) async -> Void)? = nil
    ) async throws -> BoundedCommandResult {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: BoundedCommandResult.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await runProcess(
                    executableURL: executableURL,
                    arguments: arguments,
                    currentDirectoryURL: currentDirectoryURL,
                    environment: environment,
                    inheritEnvironment: inheritEnvironment,
                    requireOwnedProcessGroup: requireOwnedProcessGroup,
                    onLaunch: onLaunch,
                    onOutput: onOutput
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BoundedCommandError.timedOut
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String],
        inheritEnvironment: Bool,
        requireOwnedProcessGroup: Bool,
        onLaunch: (@Sendable (Int32) throws -> Void)?,
        onOutput: (@Sendable (String) async -> Void)?
    ) async throws -> BoundedCommandResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw BoundedCommandError.unavailable
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessCommand-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: outputURL.path
        )
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        if !inheritEnvironment {
            process.environment = environment
        } else if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) {
                _, override in override
            }
        }
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        let startedAt = Date()
        let monitor = CommandOutputMonitor(file: outputURL)
        let outputTask = onOutput.map { observer in
            Task {
                await monitor.run(observer: observer)
            }
        }
        defer { outputTask?.cancel() }

        let lifecycle = CommandProcessLifecycle(process: process, requireOwnedProcessGroup: requireOwnedProcessGroup, onLaunch: onLaunch)
        let status = try await withTaskCancellationHandler {
            let status = try await lifecycle.run()
            try Task.checkCancellation()
            if let outputTask {
                try await monitor.finish()
                await outputTask.value
            }
            try Task.checkCancellation()
            return status
        } onCancel: {
            outputTask?.cancel()
        }
        try outputHandle.close()

        let tail = try CommandOutputTail(file: outputURL, maximumBytes: maximumOutputBytes)
        return BoundedCommandResult(
            exitCode: status,
            output: tail.text,
            outputWasTruncated: tail.wasTruncated,
            duration: Date().timeIntervalSince(startedAt)
        )
    }
}
