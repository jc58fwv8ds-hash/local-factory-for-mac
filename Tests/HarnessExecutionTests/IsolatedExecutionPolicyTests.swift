import Foundation
import CryptoKit
import HarnessCore
import Testing

struct IsolatedExecutionPolicyTests {
    @Test func scopedProfileHasNoNetworkCredentialsOrArbitraryCommandGrant() throws {
        let f = try Fixture(); defer { f.remove() }
        let profile = try f.policy().profile()
        #expect(profile.contains("(deny default)"))
        #expect(profile.contains("(allow process-exec (literal"))
        #expect(!profile.contains("allow network"))
        #expect(!profile.contains("allow mach-lookup"))
        #expect(!profile.contains("allow process-fork"))
        #expect(!profile.contains("(subpath \"/System\")"))
    }
    @Test func outsideScopeProtectedOverlapAndStaleBinaryRejected() throws {
        let f = try Fixture(); defer { f.remove() }
        #expect(throws: IsolatedExecutionPolicy.Failure.self) { try f.policy(scratch: f.base).profile() }
        #expect(throws: IsolatedExecutionPolicy.Failure.self) { try f.policy(protected: [f.scratch.appendingPathComponent("Protected.swift")]).profile() }
        #expect(throws: IsolatedExecutionPolicy.Failure.self) { try f.policy(digest: "stale").profile() }
    }
    @Test func symlinkScratchCannotEscape() throws {
        let f = try Fixture(); defer { f.remove() }
        let link = f.workspace.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.base)
        #expect(throws: IsolatedExecutionPolicy.Failure.self) { try f.policy(scratch: link).profile() }
    }
    @Test func compatibilityNotProvenNeverExecutesGeneratedBinary() async throws {
        let f = try Fixture(); defer { f.remove() }
        await #expect(throws: NativeIsolatedExecutor.Failure.self) {
            _ = try await NativeIsolatedExecutor().executeGeneratedCode(f.policy())
        }
    }
    @Test func processEnvironmentCanBeReplacedRatherThanInheritingSecrets() async throws {
        let result = try await BoundedCommandRunner(timeout: .seconds(5)).run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: [],
            environment: ["HARNESS_ISOLATION_PROBE": "only"], inheritEnvironment: false)
        #expect(result.exitCode == 0)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "HARNESS_ISOLATION_PROBE=only")
    }
    private struct Fixture {
        let base: URL, workspace: URL, scratch: URL, executable: URL, digest: String
        init() throws {
            base = URL(fileURLWithPath: "/private/tmp/harness-isolation-" + UUID().uuidString)
            workspace = base.appendingPathComponent("workspace"); scratch = workspace.appendingPathComponent("scratch")
            executable = workspace.appendingPathComponent("approved-probe")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
            digest = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
        func policy(scratch: URL? = nil, protected: [URL] = [], digest: String? = nil) -> IsolatedExecutionPolicy {
            .init(candidate: base, workspace: workspace, scratch: scratch ?? self.scratch,
                executable: executable, executableHash: digest ?? self.digest, protectedPaths: protected)
        }
    }
}
