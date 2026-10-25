import Foundation
import Testing
@testable import HarnessExecution

@Suite struct IsolatedPackageExecutionTests {
    @Test func actualPackageBuildNeverFallsBack() async throws {
        let candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let root = candidate.appendingPathComponent("work/isolation-package-probe-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources/Probe"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Tests/ProbeTests"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Probe\", targets: [.target(name: \"Probe\"), .testTarget(name: \"ProbeTests\", dependencies: [\"Probe\"])])\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public let value = 1\n".write(to: root.appendingPathComponent("Sources/Probe/Probe.swift"), atomically: true, encoding: .utf8)
        let injected = """
        import Testing
        import Probe
        import Darwin
        import Foundation
        @Test func valueIsOne() { #expect(value == 1) }
        // Read-only system data generated tests commonly use (2026-10-25: a time-zone test crashed in the sandbox).
        @Test func timeZonesResolve() { #expect(TimeZone(identifier: "America/New_York") != nil) }
        @Test func datesFormat() {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            #expect(formatter.string(from: Date(timeIntervalSince1970: 1_800_000_000)) == "2027-01-15")
        }
        @Test func forbiddenOperationsAreDeniedInTestDescendant() {
            for path in ["\(root.path)/Package.swift", "\(root.path)/../outside-\(root.lastPathComponent)"] {
                let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
                #expect(fd == -1)
                if fd >= 0 { close(fd) }
            }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd >= 0 {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = UInt16(9).bigEndian
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                #expect(result == -1 && (errno == EPERM || errno == EACCES))
                close(fd)
            } else { #expect(errno == EPERM || errno == EACCES) }
        }
        """
        try injected.write(to: root.appendingPathComponent("Tests/ProbeTests/ProbeTests.swift"), atomically: true, encoding: .utf8)
        let executor = IsolatedPackageExecution(candidate: candidate, root: root, taskID: "compatibility-probe", protectedPaths: ["Package.swift"])
        do {
            let result = try await GeneratedCodeExecutionGate.executePackage(executor, operation: .build, evidence: root.appendingPathComponent("receipts"))
            #expect(result.exitCode == 0)
            let tests = try await GeneratedCodeExecutionGate.executePackage(executor, operation: .test, evidence: root.appendingPathComponent("receipts"))
            #expect(tests.exitCode == 0)
        } catch {
            let receipts = root.appendingPathComponent("receipts")
            let receipt = try fm.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
            Issue.record("Contained build failed: \(receipt)")
        }
    }
}
