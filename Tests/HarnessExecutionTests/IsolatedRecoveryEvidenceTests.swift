import Darwin
import Foundation
import Testing
import HarnessCore
@testable import HarnessExecution

/// Restart must not infer safety from missing, ambiguous or changed evidence.
@Suite(.serialized) struct IsolatedRecoveryEvidenceTests {
    struct Fixture {
        let root: URL, stable: URL, evidence: URL, session: URL, receipt: URL
        init() throws {
            let fm = FileManager.default
            // Real non-symlinked path, as production requires for root-relative hashing.
            let candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
            root = candidate.appendingPathComponent("work/recovery-evidence-" + UUID().uuidString)
            stable = root.appendingPathComponent("stable-fixture")
            evidence = root.appendingPathComponent("receipts")
            session = evidence.appendingPathComponent("session-" + UUID().uuidString)
            receipt = evidence.appendingPathComponent("build-" + UUID().uuidString + ".json")
            try fm.createDirectory(at: root.appendingPathComponent("Sources/Probe"), withIntermediateDirectories: true)
            try fm.createDirectory(at: session, withIntermediateDirectories: true)
            try fm.createDirectory(at: stable, withIntermediateDirectories: true)
            try Data("public let value = 1".utf8).write(to: root.appendingPathComponent("Sources/Probe/Probe.swift"))
            try Data("protected".utf8).write(to: stable.appendingPathComponent("unchanged"))
            let record: [String: Any] = ["status": "starting", "worktree": root.path,
                "supervisorDirectory": session.path,
                "sourceHashesBefore": try ExecutionIntegritySnapshot.capture(root, excluding: [".harness-execution", "receipts"]),
                "stableHashesBefore": try ExecutionIntegritySnapshot.capture(stable, excluding: ["work", ".git", ".build"])]
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: receipt)
        }
        func state(_ status: String, supervisor: [String: Any] = Fixture.dead) throws {
            try JSONSerialization.data(withJSONObject: ["status": status, "supervisor": supervisor])
                .write(to: session.appendingPathComponent("state.json"))
        }
        /// Same URL construction as the CLI host (existing directory → directory URL).
        func reconcile() throws {
            try IsolatedExecutionRecovery.reconcile(evidence: URL(fileURLWithPath: evidence.path), root: root, stable: stable)
        }
        var status: String? {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])?["status"] as? String
        }
        /// Same PID, different start time: an exited process whose PID may be reused.
        static var dead: [String: Any] {["pid": getpid(), "uid": getuid(), "startedSeconds": 1, "startedMicroseconds": 1] }
        static func live() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(ExecutionProcessIdentity.current())) as! [String: Any]
        }
    }

    @Test(arguments: ["running", "CLEANUP_UNVERIFIED", "missing", "corrupt", "liveSupervisor", "liveChild"])
    func ambiguousGuardianEvidenceBlocksResume(_ condition: String) throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        switch condition {
        case "missing": break
        case "corrupt": try Data("{\"status\":".utf8).write(to: f.session.appendingPathComponent("state.json"))
        case "liveSupervisor": try f.state("INTERRUPTED_EXECUTION", supervisor: try Fixture.live())
        case "liveChild":
            try f.state("INTERRUPTED_EXECUTION")
            try JSONSerialization.data(withJSONObject: try Fixture.live()).write(to: f.session.appendingPathComponent("child.json"))
        default: try f.state(condition)
        }
        #expect(throws: (any Error).self) { try f.reconcile() }
        #expect(f.status == "starting")
    }

    @Test func heldGuardianLeaseBlocksResume() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.state("INTERRUPTED_EXECUTION")
        let lease = try LocalExecutionLease(file: f.session.appendingPathComponent("supervisor.lock"))
        #expect(throws: (any Error).self) { try f.reconcile() }
        withExtendedLifetime(lease) {}
        #expect(f.status == "starting")
    }

    @Test(arguments: ["source", "stable"])
    func changedPreconditionBlocksResume(_ target: String) throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.state("INTERRUPTED_EXECUTION")
        let file = target == "source" ? f.root.appendingPathComponent("Sources/Probe/Probe.swift") : f.stable.appendingPathComponent("unchanged")
        try Data("changed".utf8).write(to: file)
        #expect(throws: IsolatedPackageExecution.Failure.EXECUTION_ISOLATION_UNAVAILABLE) { try f.reconcile() }
        #expect(f.status == "starting")
    }

    @Test func sessionOutsideEvidenceIsRejected() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let record: [String: Any] = ["status": "starting", "supervisorDirectory": f.root.path]
        try JSONSerialization.data(withJSONObject: record).write(to: f.receipt)
        #expect(throws: IsolatedPackageExecution.Failure.invalidScope) { try f.reconcile() }
    }

    @Test func verifiedStopIsRecordedAsInterruptedNotSuccess() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.state("INTERRUPTED_EXECUTION")
        try f.reconcile()
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: f.receipt)) as? [String: Any])
        #expect(saved["status"] as? String == "INTERRUPTED_EXECUTION")
        #expect(saved["testResult"] as? String == "notVerified")
        #expect(FileManager.default.fileExists(atPath: f.receipt.appendingPathExtension("interrupted-original").path))
        // Reconciling again is idempotent and does not overwrite the preserved original.
        try f.reconcile()
    }

    /// A survivor that escaped parent links and groups still runs a scratch image.
    @Test func survivingScratchProcessBlocksExecution() async throws {
        let fm = FileManager.default
        let candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let root = candidate.appendingPathComponent("work/scratch-survivor-" + UUID().uuidString)
        let image = root.appendingPathComponent(".harness-execution/build/survivor")
        try fm.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Sources/Probe"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Probe\", targets: [.target(name: \"Probe\")])\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public let value = 1".write(to: root.appendingPathComponent("Sources/Probe/Probe.swift"), atomically: true, encoding: .utf8)
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: image)
        let survivor = Process()
        survivor.executableURL = image; survivor.arguments = ["30"]
        try survivor.run()
        defer { survivor.terminate() }
        #expect(ExecutionProcessIdentity.liveImages(under: root.appendingPathComponent(".harness-execution")) == [survivor.processIdentifier])
        let evidence = root.appendingPathComponent("receipts")
        await #expect(throws: IsolatedPackageExecution.Failure.EXECUTION_ISOLATION_UNAVAILABLE) {
            try await IsolatedPackageExecution(candidate: candidate, root: root, taskID: "survivor", protectedPaths: ["Package.swift"]).execute(.build, evidence: evidence)
        }
        #expect(try fm.contentsOfDirectory(atPath: evidence.path).isEmpty)
        survivor.terminate(); survivor.waitUntilExit()
        #expect(ExecutionProcessIdentity.liveImages(under: root.appendingPathComponent(".harness-execution")) == [])
    }

    /// Double fault: the guardian itself is killed with the host. No evidence proves
    /// cleanup, so restart must stop instead of re-executing or declaring success.
    @Test func hostAndGuardianSIGKILLBlocksRestart() async throws {
        let fm = FileManager.default
        let candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let root = candidate.appendingPathComponent("work/guardian-death-" + UUID().uuidString)
        let stable = root.appendingPathComponent("stable-fixture")
        try fm.createDirectory(at: root.appendingPathComponent("Sources/Probe"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stable, withIntermediateDirectories: true)
        try Data("protected".utf8).write(to: stable.appendingPathComponent("unchanged"))
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
        func launch() throws -> Process {
            let process = Process()
            process.executableURL = candidate.appendingPathComponent(".build/debug/HarnessKernelPilot")
            process.arguments = ["--isolated-package-host", candidate.path, root.path, evidence.path, "build", stable.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); return process
        }
        let host = try launch()
        defer { if host.isRunning { host.terminate() } }
        for _ in 0..<150 { if fm.fileExists(atPath: marker.path) { break }; try await Task.sleep(for: .milliseconds(100)) }
        guard fm.fileExists(atPath: marker.path) else { Issue.record("Isolated child did not start"); return }
        let orphan = try #require(ExecutionProcessIdentity.read(Int32(String(contentsOf: marker, encoding: .utf8))!))
        let session = try #require(try fm.contentsOfDirectory(at: evidence, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("session-") })
        let state = try JSONDecoder().decode(ExecutionSupervisor.State.self, from: Data(contentsOf: session.appendingPathComponent("state.json")))
        let launched = try #require(try? JSONDecoder().decode(ExecutionProcessIdentity.self, from: Data(contentsOf: session.appendingPathComponent("child.json"))))
        defer {
            // Test hygiene only: identity-checked kill of the processes this test started.
            for identity in [orphan, launched] where identity.isAlive { kill(identity.pid, SIGKILL) }
        }
        #expect(state.supervisor.isAlive)
        #expect(kill(state.supervisor.pid, SIGKILL) == 0)
        #expect(kill(host.processIdentifier, SIGKILL) == 0)
        for _ in 0..<50 { if !host.isRunning && !state.supervisor.isAlive { break }; try await Task.sleep(for: .milliseconds(50)) }
        let restarted = try launch()
        for _ in 0..<150 { if !restarted.isRunning { break }; try await Task.sleep(for: .milliseconds(100)) }
        #expect(!restarted.isRunning && restarted.terminationStatus != 0)
        let states = try fm.contentsOfDirectory(at: evidence, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(states.count == 1)
        #expect(!states.contains { $0.contains("commandPassed") || $0.contains("INTERRUPTED_EXECUTION") })
        #expect(try String(contentsOf: session.appendingPathComponent("state.json"), encoding: .utf8).contains("running"))
        #expect(try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8) == manifest)
    }
}
