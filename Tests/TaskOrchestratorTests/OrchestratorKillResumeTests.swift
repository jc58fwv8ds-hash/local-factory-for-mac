import Foundation
import Testing
import HarnessExecution
import HarnessKernel
@testable import TaskOrchestrator

/// Phase B.3: kill at every durable stage boundary, then resume. A kill is modelled by a disk image of the
/// package and the run output taken at the boundary (no write is in flight there; mid-write kills are covered
/// by RecoverableFileBatch's SIGKILL tests). Each image is restored in place and resumed.
extension BatchPipelineReplayTests {
    final class Images: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var labels: [String] = []
        let directory: URL
        init(directory: URL) { self.directory = directory }
        func capture(_ label: String, root: URL, output: URL) {
            lock.withLock {
                let image = directory.appendingPathComponent("\(labels.count)")
                try! FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
                try! FileManager.default.copyItem(at: root, to: image.appendingPathComponent("package"))
                try! FileManager.default.copyItem(at: output, to: image.appendingPathComponent("output"))
                labels.append(label)
            }
        }
    }

    static func restore(_ image: URL, root: URL, output: URL) throws {
        for (from, to) in [("package", root), ("output", output)] {
            try FileManager.default.removeItem(at: to)
            try FileManager.default.copyItem(at: image.appendingPathComponent(from), to: to)
        }
    }

    func killResume(_ name: String, plans: [String], edits: [String], expectedBoundaries: Int) async throws {
        let (root, output, cleanup) = try fixture(name)
        defer { cleanup() }
        let images = Images(directory: root.deletingLastPathComponent().appendingPathComponent("images"))
        let script = Script(plans: plans, edits: edits)
        try await PilotModelSeam.$script.withValue(.init(respond: { try await script.respond($0) })) {
            try await OrchestratorFaultSeam.$boundary.withValue({ images.capture($0, root: root, output: output) }) {
                try await TaskOrchestrator.runTask(candidate: candidate, root: root, key: "b3-\(name)", model: "scripted", output: output)
            }
        }
        // Uninterrupted run: the journal alone reproduces the record's final phase.
        let final = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("result.json"))) as! [String: Any]
        let finalState = try #require(try OrchestratorLedger.replay(directory: output.appendingPathComponent("kernel")))
        #expect(finalState.phase == .paused && finalState.pauseReason == final["phase"] as? String, "\(final)")
        #expect(images.labels.count == expectedBoundaries, "\(images.labels)")

        let forbidden = Script(plans: [], edits: [])                       // resume must never reach the model
        for (index, label) in images.labels.enumerated() {
            try Self.restore(images.directory.appendingPathComponent("\(index)"), root: root, output: output)
            let outcome = try await PilotModelSeam.$script.withValue(.init(respond: { try await forbidden.respond($0) })) {
                try await TaskOrchestrator.resume(root: root, output: output)
            }
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("result.json"))) as! [String: Any]
            let source = try String(contentsOf: root.appendingPathComponent(Self.sourcePath), encoding: .utf8)
            let state = try #require(try OrchestratorLedger.replay(directory: output.appendingPathComponent("kernel")))
            #expect(state.phase == .paused && state.activeAttempt == nil, "\(label)")
            #expect(state.pauseReason == record["phase"] as? String, "\(label): journal \(state.pauseReason ?? "-") vs record \(record["phase"] ?? "-")")
            if label == "finished:requirementGate" {
                #expect(outcome == .closedAtRequirementGate, "\(label)")
                #expect(record["phase"] as? String == "testsPassedRequirementVerificationPending")
                #expect(source.contains("min(v, 10)"), "\(label)")
            } else {
                guard case .stoppedFailClosed(let stage, let rollback) = outcome else { Issue.record("\(label): \(outcome)"); continue }
                #expect(record["phase"] as? String == "interrupted:\(stage)" && record["harnessResult"] as? String == "HARNESS_FAIL", "\(label)")
                #expect(rollback == "PASS" || rollback == "NOT_NEEDED", "\(label): \(rollback)")
                #expect(source == Self.meter, "\(label): edit left behind")          // no duplicate or stale apply
                #expect(record["protectedFilesIntact"] as? Bool != false, "\(label)")
            }
            #expect(try await TaskOrchestrator.resume(root: root, output: output) == .alreadyStopped(record["phase"] as! String))
        }
        #expect(await forbidden.allPrompts().isEmpty)
    }

    @Test func killAtEveryBoundaryOfAPassingRunResumesSafely() async throws {
        try await killResume("kill-pass", plans: [Self.plan()], edits: [Self.edit("return v", "return min(v, 10)")],
                             expectedBoundaries: 2 * OrchestratorLedger.stages.count)
    }

    @Test func killAtEveryBoundaryOfAReplannedRunResumesSafely() async throws {
        // Two different wrong edits (an identical second proposal stops at propose: replanRepeated).
        // context + two full attempts of plan/propose/apply/build/test; no requirement gate.
        try await killResume("kill-replan", plans: [Self.plan(), Self.plan()],
            edits: [Self.edit("return v", "return min(v, 9)"), Self.edit("return v", "return min(v, 8)")], expectedBoundaries: 2 + 2 * 10)
    }
}
