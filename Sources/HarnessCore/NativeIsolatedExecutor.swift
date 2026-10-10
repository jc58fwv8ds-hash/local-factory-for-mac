import Foundation

/// Narrow native runtime adapter. Build tools/signing are deliberately not admitted.
public struct NativeIsolatedExecutor: Sendable {
    public enum Failure: Error { case compatibilityUnverified }
    public init() {}
    /// A host-authored benign probe must succeed under the exact same restrictions first.
    /// This is not a general SwiftPM build/test adapter.
    public func probe(_ policy: IsolatedExecutionPolicy) async throws -> BoundedCommandResult {
        let profile = try policy.profile()
        return try await BoundedCommandRunner(timeout: .seconds(10)).run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-p", profile, policy.executable.path],
            currentDirectoryURL: policy.scratch,
            environment: ["PATH": "/usr/bin:/bin", "HOME": policy.scratch.path, "TMPDIR": policy.scratch.path],
            inheritEnvironment: false)
    }
    public func executeGeneratedCode(_ policy: IsolatedExecutionPolicy) async throws -> BoundedCommandResult {
        // The native diagnostic probe passes, but this does not attest a generated
        // build/test pipeline. No approval via a boolean/model claim; fail closed
        // until that runtime adapter and its admission proof are implemented.
        _ = try policy.profile()
        throw Failure.compatibilityUnverified
    }
}
