import Foundation
import HarnessKernelContracts

public enum KernelPhase: String, Sendable {
    case unplanned, ready, executing, paused, completed
}

public struct KernelAttempt: Equatable, Sendable {
    public let stepID: UUID
    public let id: UUID
}

/// Rebuilt from the journal; never persisted independently of its evidence.
public struct KernelState: Sendable {
    public let runID: UUID
    public private(set) var sequence = 0
    public private(set) var phase = KernelPhase.unplanned
    public private(set) var plan: KernelPlan?
    public private(set) var modelIdentifier: String?
    public private(set) var revision = 0
    public private(set) var activeAttempt: KernelAttempt?
    public private(set) var completedStepIDs = Set<UUID>()
    public private(set) var evidence: [UUID: KernelEvidence] = [:]
    public private(set) var lastDecision: String?
    public private(set) var pauseReason: String?
    public private(set) var attemptCounts: [UUID: Int] = [:]
    private var usedAttemptIDs = Set<UUID>()

    public init(runID: UUID) { self.runID = runID }

    public var nextStep: KernelStep? {
        plan?.steps.first { !completedStepIDs.contains($0.id) }
    }

    /// An active attempt after reload requires external reconciliation, never automatic retry.
    public var canComplete: Bool {
        guard let plan, phase == .ready, activeAttempt == nil, nextStep == nil else { return false }
        return plan.requirements.allSatisfy {
            guard let result = evidence[$0.id] else { return false }
            return result.passed && result.revision == revision
        }
    }

    public mutating func apply(_ event: KernelEvent) throws {
        guard event.schemaVersion == 1 else { throw KernelError.unsupportedSchema }
        guard event.runID == runID, event.sequence == sequence + 1 else {
            throw KernelError.invalidEventOrder
        }
        guard phase != .completed else { throw KernelError.invalidTransition }
        switch event.payload {
        case .planned(let newPlan):
            guard phase == .unplanned else { throw KernelError.invalidTransition }
            guard newPlan.isValid else { throw KernelError.invalidPlan }
            plan = newPlan
            modelIdentifier = newPlan.modelIdentifier
            phase = .ready
        case .stepStarted(let stepID, let attemptID):
            guard activeAttempt == nil else { throw KernelError.unresolvedAttempt }
            guard phase == .ready, nextStep?.id == stepID, !usedAttemptIDs.contains(attemptID) else {
                throw KernelError.invalidTransition
            }
            usedAttemptIDs.insert(attemptID)
            attemptCounts[stepID, default: 0] += 1
            activeAttempt = KernelAttempt(stepID: stepID, id: attemptID)
            revision += 1
            evidence.removeAll()
            phase = .executing
        case .stepFinished(let attemptID, let succeeded):
            guard let attempt = activeAttempt, attempt.id == attemptID,
                  phase == .executing || phase == .paused else { throw KernelError.invalidTransition }
            if succeeded { completedStepIDs.insert(attempt.stepID) }
            activeAttempt = nil
            if phase == .executing { phase = .ready }
        case .stepReopened(let stepID, let reason):
            guard activeAttempt == nil else { throw KernelError.unresolvedAttempt }
            guard phase == .ready || phase == .paused,
                  let steps = plan?.steps,
                  let index = steps.firstIndex(where: { $0.id == stepID }),
                  completedStepIDs.contains(stepID),
                  !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KernelError.invalidTransition
            }
            completedStepIDs.subtract(steps[index...].map(\.id))
            revision += 1
            evidence.removeAll()
            lastDecision = reason
        case .verificationRecorded(let result):
            guard phase == .ready, nextStep == nil, activeAttempt == nil,
                  plan?.requirements.contains(where: { $0.id == result.requirementID }) == true,
                  result.revision == revision,
                  !result.reportReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KernelError.invalidEvidence
            }
            evidence[result.requirementID] = result
        case .decisionRecorded(let decision):
            guard plan != nil, !decision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KernelError.invalidTransition
            }
            // Reserved routing records are validated during both append and replay.
            // Corrupt or future records must not silently become ordinary prose.
            if let routing = try KernelRoutingRecord.decode(event.payload) {
                guard phase == .ready, activeAttempt == nil,
                      routing.stepID == nextStep?.id, routing.revision == revision else {
                    throw KernelError.invalidTransition
                }
            }
            lastDecision = decision
        case .paused(let reason):
            guard phase == .ready || phase == .executing,
                  !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KernelError.invalidTransition
            }
            phase = .paused
            pauseReason = reason
        case .resumed(let model):
            guard activeAttempt == nil else { throw KernelError.unresolvedAttempt }
            guard phase == .paused, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KernelError.invalidTransition
            }
            modelIdentifier = model
            phase = .ready
            pauseReason = nil
        case .completed:
            guard canComplete else { throw KernelError.completionNotVerified }
            phase = .completed
        }
        sequence = event.sequence
    }
}
