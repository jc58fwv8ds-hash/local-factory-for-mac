import Foundation
import HarnessKernel
import HarnessKernelContracts
import HarnessKernelPersistence

/// The parent Kernel Run of one orchestrated task. Every pipeline stage is a Kernel step whose start
/// and end are durable before the stage proceeds, so a killed process leaves a journal that says
/// exactly which stage was in flight. The run never reaches `completed` here: its only requirement is
/// the external independent requirement verification, so a finished run ends `paused` with the
/// result phase as the reason (`testsPassedRequirementVerificationPending` or `failed:<stage>`).
package final class OrchestratorLedger: @unchecked Sendable {
    package static let stages = ["context", "plan", "propose", "apply", "build", "test", "requirementGate"]
    package static let requirement = "External independent requirement verification (REQUIREMENT_VERIFICATION_SATISFIED)"
    private let engine: KernelEngine

    /// Opens the journal in `directory`, planning the fixed stage sequence when it is new.
    package init(directory: URL, objective: String, model: String) async throws {
        let journal = try FileKernelJournal(directory: directory)
        let runID = try journal.read().first?.runID ?? UUID()
        engine = try KernelEngine(runID: runID, journal: journal)
        if await engine.snapshot().phase == .unplanned {
            try await engine.record(.planned(KernelPlan(userRequest: objective, modelIdentifier: model,
                steps: Self.stages.map { KernelStep(instruction: $0) },
                requirements: [VerificationRequirement(criterion: Self.requirement, kind: .acceptance)])))
        }
    }

    /// Rebuilds the run from its journal alone (no result record is consulted).
    package static func replay(directory: URL) throws -> KernelState? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let events = try FileKernelJournal(directory: directory).read()
        guard let runID = events.first?.runID else { return nil }
        var state = KernelState(runID: runID)
        for event in events { try state.apply(event) }
        return state
    }

    package static func stage(of attempt: KernelAttempt?, in state: KernelState) -> String? {
        attempt.flatMap { a in state.plan?.steps.first { $0.id == a.stepID }?.instruction }
    }

    package func snapshot() async -> KernelState { await engine.snapshot() }

    /// Starts `stage`; a stage completed earlier (a replan) is reopened first with `reason`.
    func begin(_ stage: String, reopening reason: String = "replan") async throws {
        let state = await engine.snapshot()
        guard let step = state.plan?.steps.first(where: { $0.instruction == stage }) else { throw KernelError.invalidPlan }
        if state.completedStepIDs.contains(step.id) { try await engine.record(.stepReopened(stepID: step.id, reason: reason)) }
        // Stages skipped on this path (none today) would be reported as an order violation by the Kernel.
        try await engine.record(.stepStarted(stepID: step.id, attemptID: UUID()))
        await OrchestratorFaultSeam.boundary?("started:\(stage)")
    }

    func end(_ stage: String, succeeded: Bool = true) async throws {
        guard let attempt = await engine.snapshot().activeAttempt else { throw KernelError.invalidTransition }
        try await engine.record(.stepFinished(attemptID: attempt.id, succeeded: succeeded))
        await OrchestratorFaultSeam.boundary?("finished:\(stage)")
    }

    /// Ends the run: an in-flight stage is closed as failed unless `succeeded`, then the run pauses with `phase`.
    package func stop(phase: String, succeeded: Bool = false) async throws {
        let state = await engine.snapshot()
        guard state.phase != .paused else { return }
        if let attempt = state.activeAttempt {
            try await engine.record(.stepFinished(attemptID: attempt.id, succeeded: succeeded))
        }
        try await engine.record(.paused(reason: phase))
    }
}

/// Deterministic fault-injection seam for kill/resume tests. Production never binds it. The hook runs
/// after each durable stage boundary, when no write is in flight, so a disk snapshot taken there is
/// exactly what a process kill at that boundary leaves behind.
package enum OrchestratorFaultSeam {
    @TaskLocal package static var boundary: (@Sendable (String) async -> Void)?
}
