import Foundation

/// Out-of-process ownership: survives the UI/worker host and holds its own lease.
public enum ExecutionSupervisor {
    public enum Failure: Error { case ambiguous, interrupted }
    public struct Request: Codable, Sendable {
        let owner: ExecutionProcessIdentity
        let arguments: [String]
        let workspace: URL
        let environment: [String: String]
    }
    public struct State: Codable, Sendable {
        public let status: String
        public let supervisor: ExecutionProcessIdentity
        public let result: BoundedCommandResult?
    }
    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        try file.synchronize(); try file.close()
    }
    public static func run(helper: URL, directory: URL, arguments: [String], workspace: URL,
                           environment: [String: String]) async throws -> BoundedCommandResult {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let request = Request(owner: try .current(), arguments: arguments, workspace: workspace, environment: environment)
        try save(request, to: directory.appendingPathComponent("request.json"))
        let waiter = Task.detached {
            try await BoundedCommandRunner(timeout: .seconds(110)).run(executableURL: helper,
                arguments: ["--execution-supervisor", directory.path], inheritEnvironment: false)
        }
        // Cancelling this wait does not make an unfinished execution successful.
        // A request file asks the surviving supervisor to stop its own process tree.
        do {
            return try await withTaskCancellationHandler {
                _ = try await waiter.value
                let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
                guard state.status == "completed", let result = state.result else { throw Failure.interrupted }
                return result
            } onCancel: {
                // Normal cancellation must not kill the guardian before it cleans up.
                try? Data().write(to: directory.appendingPathComponent("cancel"), options: .atomic)
            }
        } catch { throw error }
    }
    public static func serve(directory: URL) async throws {
        let lease = try LocalExecutionLease(file: directory.appendingPathComponent("supervisor.lock"))
        defer { withExtendedLifetime(lease) {} }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: directory.appendingPathComponent("request.json")))
        let identity = try ExecutionProcessIdentity.current()
        let stateURL = directory.appendingPathComponent("state.json")
        guard !FileManager.default.fileExists(atPath: stateURL.path) else { throw Failure.ambiguous }
        try save(State(status: "running", supervisor: identity, result: nil), to: stateURL)
        guard request.owner.isAlive else {
            try save(State(status: "INTERRUPTED_EXECUTION", supervisor: identity, result: nil), to: stateURL)
            return
        }
        do {
            let result = try await withThrowingTaskGroup(of: BoundedCommandResult.self) { group in
                group.addTask {
                    do { return try await BoundedCommandRunner(timeout: .seconds(90)).run(
                        executableURL: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), arguments: request.arguments,
                        currentDirectoryURL: request.workspace, environment: request.environment,
                        inheritEnvironment: false, requireOwnedProcessGroup: true, onLaunch: { pid in
                            guard let child = ExecutionProcessIdentity.read(pid) else { throw Failure.ambiguous }
                            try save(child, to: directory.appendingPathComponent("child.json"))
                        })
                    } catch {
                        if (error as? BoundedCommandError) == .cleanupUnverified {
                            try? Data().write(to: directory.appendingPathComponent("cleanup-unverified"))
                        }
                        throw error
                    }
                }
                group.addTask {
                    while request.owner.isAlive && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancel").path) {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    throw Failure.interrupted
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw Failure.ambiguous }
                return result
            }
            try save(State(status: request.owner.isAlive ? "completed" : "INTERRUPTED_EXECUTION", supervisor: identity, result: result), to: stateURL)
        } catch {
            let childURL = directory.appendingPathComponent("child.json")
            let child = try? JSONDecoder().decode(ExecutionProcessIdentity.self, from: Data(contentsOf: childURL))
            let status = child?.isAlive == false && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("cleanup-unverified").path) ? "INTERRUPTED_EXECUTION" : "CLEANUP_UNVERIFIED"
            try save(State(status: status, supervisor: identity, result: nil), to: stateURL)
        }
    }
    /// Restart only accepts a terminal guardian receipt and an available execution lease.
    /// Missing/corrupt/running/ambiguous receipts never authorize a retry or PID-only kill.
    public static func verifyStopped(directory: URL) throws {
        let lease = try LocalExecutionLease(file: directory.appendingPathComponent("supervisor.lock"))
        defer { withExtendedLifetime(lease) {} }
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
        guard ["completed", "INTERRUPTED_EXECUTION"].contains(state.status), !state.supervisor.isAlive else { throw Failure.ambiguous }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("child.json").path) {
            let child = try JSONDecoder().decode(ExecutionProcessIdentity.self, from: Data(contentsOf: directory.appendingPathComponent("child.json")))
            guard !child.isAlive else { throw Failure.ambiguous }
        }
    }
}
