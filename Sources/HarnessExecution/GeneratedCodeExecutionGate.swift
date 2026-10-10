import Foundation
import HarnessCore

/// Deliberate fail-closed interlock until an actual runtime containment adapter is verified.
/// SwiftPM's manifest/plugin sandbox is not runtime containment for generated tests.
public enum GeneratedCodeExecutionGate {
    /// Only this concrete contained adapter is admitted; no arbitrary provider,
    /// model assertion, or unrestricted fallback is accepted by this entry point.
    public static func executePackage(_ adapter: IsolatedPackageExecution,
                                      operation: IsolatedPackageExecution.Operation,
                                      evidence: URL) async throws -> BoundedCommandResult {
        try await adapter.execute(operation, evidence: evidence)
    }
    public enum Failure: Error { case runtimeIsolationUnverified }
    public static func requireRuntimeIsolation() throws {
        throw Failure.runtimeIsolationUnverified
    }
}
