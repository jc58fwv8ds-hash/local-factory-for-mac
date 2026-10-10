import Foundation
import HarnessKernel
import HarnessKernelContracts
import HarnessKernelPersistence
import Testing

struct KernelRoutedStartTests {
    @Test(arguments: ["allowed", "blocked", "review", "superseded", "replayed"])
    func onlyCurrentUnrestrictedToolDecisionCanStart(mode: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try FileKernelJournal(directory: directory)
        let runID = UUID()
        let engine = try KernelEngine(runID: runID, journal: journal)
        let plan = KernelPlan(userRequest: "テスト", modelIdentifier: "tools",
            steps: [.init(instruction: "検証")], requirements: [.init(criterion: "成功", kind: .unit)])
        try await engine.record(.planned(plan))
        let decision = KernelRoutingPolicy.decide(work: mode == "blocked" ? .focusedEdit : .deterministic,
            localCompatible: false, subscriptionDispatchVerified: false, solAvailable: false,
            astraAvailable: false, materialRisk: mode == "review")
        let receipt = try await engine.recordRoutingDecision(decision)
        if mode == "superseded" { try await engine.record(.decisionRecorded("計画を見直す")) }
        if mode == "allowed" || mode == "replayed" {
            let attempt = UUID()
            let started = try await engine.startDeterministicStep(using: receipt, attemptID: attempt)
            #expect(started.activeAttempt?.id == attempt)
            if mode == "replayed" {
                try await engine.record(.stepFinished(attemptID: attempt, succeeded: false))
                let recovered = try KernelEngine(runID: runID, journal: journal)
                await #expect(throws: KernelError.invalidTransition) {
                    try await recovered.startDeterministicStep(using: receipt, attemptID: UUID())
                }
                #expect(await recovered.snapshot().activeAttempt == nil)
            }
        } else {
            let before = await engine.snapshot().sequence
            await #expect(throws: KernelError.invalidTransition) {
                try await engine.startDeterministicStep(using: receipt, attemptID: UUID())
            }
            #expect(await engine.snapshot().sequence == before)
            #expect(await engine.snapshot().activeAttempt == nil)
        }
    }
}
