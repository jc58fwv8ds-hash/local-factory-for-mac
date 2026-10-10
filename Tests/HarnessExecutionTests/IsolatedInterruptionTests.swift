import Foundation
import Darwin
import Testing
@testable import HarnessExecution

@Suite struct IsolatedInterruptionTests {
    @Test func cancelBuildStopsManifestChildAndFreshExecutorResumes() async throws {
        let candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let root = candidate.appendingPathComponent("work/isolation-interrupt-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources/Probe"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let marker = root.appendingPathComponent(".harness-execution/child.pid")
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        import Foundation
        import Darwin
        let marker = "\(marker.path)"
        if !FileManager.default.fileExists(atPath: marker) {
            try String(getpid()).write(toFile: marker, atomically: true, encoding: .utf8)
            sleep(30)
        }
        let package = Package(name: "Probe", targets: [.target(name: "Probe")])
        """
        try manifest.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public let value = 1".write(to: root.appendingPathComponent("Sources/Probe/Probe.swift"), atomically: true, encoding: .utf8)
        let evidence = root.appendingPathComponent("receipts")
        let operation = Task {
            try await IsolatedPackageExecution(candidate: candidate, root: root, taskID: "interrupt", protectedPaths: ["Package.swift"]).execute(.build, evidence: evidence)
        }
        for _ in 0..<100 {
            if fm.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard fm.fileExists(atPath: marker.path) else {
            operation.cancel(); _ = try? await operation.value
            Issue.record("Manifest child did not start under isolation"); return
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        operation.cancel()
        do { _ = try await operation.value; Issue.record("Cancelled build was accepted") } catch {}
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        let resumed = try await IsolatedPackageExecution(candidate: candidate, root: root, taskID: "interrupt", protectedPaths: ["Package.swift"]).execute(.build, evidence: evidence)
        #expect(resumed.exitCode == 0)
        #expect(try fm.contentsOfDirectory(atPath: evidence.path).filter { $0.hasSuffix(".json") }.count == 2)
        try Data("{\"status\":\"starting\"}".utf8).write(to: evidence.appendingPathComponent("unclosed-crash.json"))
        do {
            _ = try await IsolatedPackageExecution(candidate: candidate, root: root, taskID: "interrupt", protectedPaths: ["Package.swift"]).execute(.build, evidence: evidence)
            Issue.record("Unclosed execution was silently retried")
        } catch IsolatedPackageExecution.Failure.EXECUTION_ISOLATION_UNAVAILABLE {}
        #expect(try fm.contentsOfDirectory(atPath: evidence.path).filter { $0.hasSuffix(".json") }.count == 3)
    }
}
