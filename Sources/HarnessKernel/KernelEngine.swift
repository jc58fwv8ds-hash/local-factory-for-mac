import Foundation
import HarnessKernelContracts

/// Headless state engine. Tool execution and trusted verification adapters are wired in later.
public actor KernelEngine {
    private let journal: any KernelJournal
    private var state: KernelState

    public init(runID: UUID, journal: any KernelJournal) throws {
        self.journal = journal
        var recovered = KernelState(runID: runID)
        for event in try journal.read() { try recovered.apply(event) }
        self.state = recovered
    }

    public func snapshot() -> KernelState { state }

    /// Durable route evidence for the next step. No provider or tool is invoked.
    /// Keeping this actor-isolated avoids recording against a stale step/revision.
    public func recordRoutingDecision(_ decision: KernelRoutingPolicy.Decision) throws -> KernelRoutingRecord {
        guard state.phase == .ready, state.activeAttempt == nil,
              let step = state.nextStep else { throw KernelError.invalidTransition }
        let receipt = KernelRoutingRecord(stepID: step.id, revision: state.revision, decision: decision)
        try record(.decisionRecorded(receipt.encodedDecision()))
        return receipt
    }

    /// The migrated deterministic path must present the current recorded decision.
    /// This is not permission to run arbitrary commands or external model providers.
    public func startDeterministicStep(using receipt: KernelRoutingRecord, attemptID: UUID) throws -> KernelState {
        guard state.phase == .ready, state.activeAttempt == nil,
              receipt.stepID == state.nextStep?.id, receipt.revision == state.revision,
              receipt.decision.route == .tools, !receipt.decision.independentReviewRequired,
              state.lastDecision == (try receipt.encodedDecision()) else {
            throw KernelError.invalidTransition
        }
        return try record(.stepStarted(stepID: receipt.stepID, attemptID: attemptID))
    }

    @discardableResult
    public func record(_ payload: KernelEventPayload) throws -> KernelState {
        let event = KernelEvent(runID: state.runID, sequence: state.sequence + 1, payload: payload)
        var candidate = state
        try candidate.apply(event)
        if case .stepStarted(let stepID, _) = payload,
           let reason = KernelExecutionBudget.stopReason(state: state, stepID: stepID) {
            // Persist the stop before reporting it. A rejected attempt is never recorded.
            try record(.paused(reason: reason))
            throw KernelError.executionBudgetExceeded
        }
        try journal.append(event)
        state = candidate
        return state
    }
}
