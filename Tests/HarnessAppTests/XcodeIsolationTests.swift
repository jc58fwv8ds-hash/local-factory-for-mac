import Foundation
import HarnessCore
import Testing

/// 2026-10-12 review: Xcode projects were built and tested without the OS sandbox. Now build and test run inside one
/// with no network and writes only to the run's folder and macOS's per-user temporary and cache folders.
struct XcodeIsolationTests {
    @Test func theProfileBlocksTheNetworkAndConfinesWrites() {
        let work = URL(fileURLWithPath: "/tmp/HarnessDerivedData-x")
        let profile = XcodeIsolation.profile(workDirectory: work)
        #expect(profile.contains("(deny network*)") && profile.contains("(deny file-write*)"))
        #expect(profile.contains("(subpath \"/private/tmp/HarnessDerivedData-x\")"))   // the real path, not the /tmp link
        #expect(profile.contains("/private/var/folders/"))
        #expect(!profile.contains("(subpath \"/Users"))
    }

    @Test func aSandboxedCommandCannotWriteOutsideOrReachTheNetwork() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("xcode-isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        func run(_ arguments: [String]) -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", XcodeIsolation.profile(workDirectory: work)] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        let outside = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("harness-isolation-\(UUID().uuidString)")
        #expect(run(["/usr/bin/touch", outside.path]) != 0)
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(run(["/usr/bin/touch", work.appendingPathComponent("inside").path]) == 0)
        #expect(run(["/usr/bin/curl", "-s", "-m", "5", "-o", "/dev/null", "https://example.com"]) != 0)
    }

    /// The real verification of the repository's iPhone app, build and Simulator tests inside the sandbox (about a minute).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_XCODE_TESTS"] == "1"))
    func harnessRemoteBuildsAndTestsInsideTheSandbox() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HarnessRemote")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("xcode-isolation-app-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let report = try await XcodeProjectValidationService().validate(rootPath: copy.path)
        for check in report.checks { #expect(check.succeeded, "\(check.kind): \(check.output.suffix(1500))") }
        #expect(report.checks.first?.output.contains("隔離(通信なし)") == true)
    }
}
