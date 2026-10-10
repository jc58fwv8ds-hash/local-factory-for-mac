import Foundation
import HarnessKernel
import HarnessKernelContracts
import HarnessKernelPersistence
import Testing

struct KernelRoutingPersistenceTests {
    @Test func receiptSurvivesRestartAndStaleWriterCannotReportSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try FileKernelJournal(directory: directory)
        let runID = UUID()
        let engine = try KernelEngine(runID: runID, journal: journal)
        let plan = KernelPlan(userRequest: "保存を確認", modelIdentifier: "local",
            steps: [.init(instruction: "テスト")], requirements: [.init(criterion: "成功", kind: .unit)])
        let decision = KernelRoutingPolicy.decide(work: .deterministic, localCompatible: false,
            subscriptionDispatchVerified: false, solAvailable: false, astraAvailable: false)
        await #expect(throws: KernelError.invalidTransition) { try await engine.recordRoutingDecision(decision) }
        try await engine.record(.planned(plan))
        let stale = try KernelEngine(runID: runID, journal: journal)
        let receipt = try await engine.recordRoutingDecision(decision)
        #expect(receipt.stepID == plan.steps[0].id)
        #expect(receipt.revision == 0)
        let recovered = try KernelEngine(runID: runID, journal: journal)
        #expect(await recovered.snapshot().sequence == 2)
        let event = try #require(journal.read().last)
        #expect(try KernelRoutingRecord.decode(event.payload) == receipt)
        await #expect(throws: KernelError.journalConflict) { try await stale.recordRoutingDecision(decision) }
        #expect(await stale.snapshot().sequence == 1)
        try await recovered.record(.stepStarted(stepID: plan.steps[0].id, attemptID: UUID()))
        await #expect(throws: KernelError.invalidTransition) { try await recovered.recordRoutingDecision(decision) }
    }

    @Test func legacyDecisionsAreNotReinterpretedAsRoutes() throws {
        #expect(try KernelRoutingRecord.decode(.decisionRecorded("確認してから実行")) == nil)
        #expect(throws: (any Error).self) {
            try KernelRoutingRecord.decode(.decisionRecorded("harness-routing-v1:broken"))
        }
    }

    @Test(arguments: ["harness-routing-v1:broken", "harness-routing-v2:{}"])
    func malformedRoutingCannotAdvanceState(text: String) throws {
        var state = KernelState(runID: UUID())
        let plan = KernelPlan(userRequest: "検証", modelIdentifier: "local",
            steps: [.init(instruction: "テスト")], requirements: [.init(criterion: "成功", kind: .unit)])
        try state.apply(KernelEvent(runID: state.runID, sequence: 1, payload: .planned(plan)))
        #expect(throws: (any Error).self) {
            try state.apply(KernelEvent(runID: state.runID, sequence: 2, payload: .decisionRecorded(text)))
        }
        #expect(state.sequence == 1)
        #expect(state.lastDecision == nil)
    }
}
