import Foundation
@testable import HarnessKernel
import HarnessKernelContracts
import HarnessKernelPersistence
import Testing

struct KernelExecutionBudgetTests {
    @Test(arguments: [false, true])
    func restartAndReopenDoNotResetAttemptBudget(succeeded: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessBudget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try FileKernelJournal(directory: directory)
        let runID = UUID()
        let plan = makePlan(count: 1)
        let stepID = plan.steps[0].id
        let engine = try KernelEngine(runID: runID, journal: journal)
        try await engine.record(.planned(plan))
        for _ in 0..<3 {
            let attempt = UUID()
            try await engine.record(.stepStarted(stepID: stepID, attemptID: attempt))
            try await engine.record(.stepFinished(attemptID: attempt, succeeded: succeeded))
            if succeeded { try await engine.record(.stepReopened(stepID: stepID, reason: "受入条件の追加確認")) }
        }
        let recovered = try KernelEngine(runID: runID, journal: journal)
        await #expect(throws: KernelError.executionBudgetExceeded) {
            try await recovered.record(.stepStarted(stepID: stepID, attemptID: UUID()))
        }
        let stopped = await recovered.snapshot()
        #expect(stopped.phase == .paused)
        #expect(stopped.activeAttempt == nil)
        #expect(stopped.attemptCounts[stepID] == 3)
        #expect(stopped.pauseReason != nil)
        #expect(!stopped.canComplete)
        let reloaded = try KernelEngine(runID: runID, journal: journal)
        #expect(await reloaded.snapshot().phase == .paused)
        try await reloaded.record(.resumed(modelIdentifier: "another-model"))
        await #expect(throws: KernelError.executionBudgetExceeded) {
            try await reloaded.record(.stepStarted(stepID: stepID, attemptID: UUID()))
        }
        #expect(await reloaded.snapshot().attemptCounts[stepID] == 3)
    }

    @Test func runBudgetIsIndependentOfStepBudget() throws {
        var state = KernelState(runID: UUID())
        let plan = makePlan(count: 100)
        func apply(_ payload: KernelEventPayload) throws {
            try state.apply(KernelEvent(runID: state.runID, sequence: state.sequence + 1, payload: payload))
        }
        try apply(.planned(plan))
        for (index, step) in plan.steps.enumerated() {
            for attemptIndex in 0..<2 {
                #expect(KernelExecutionBudget.stopReason(state: state, stepID: step.id) == nil)
                let attempt = UUID()
                try apply(.stepStarted(stepID: step.id, attemptID: attempt))
                try apply(.stepFinished(attemptID: attempt, succeeded: attemptIndex == 1 && index < 99))
            }
        }
        let last = try #require(plan.steps.last)
        #expect(state.attemptCounts[last.id] == 2)
        #expect(KernelExecutionBudget.stopReason(state: state, stepID: last.id) != nil)
    }

    private func makePlan(count: Int) -> KernelPlan {
        KernelPlan(userRequest: "アプリを作って", modelIdentifier: "local",
            steps: (0..<count).map { KernelStep(instruction: "作業\($0)") },
            requirements: [.init(criterion: "保存と復元ができる", kind: .unit)])
    }
}
