import Foundation

public enum KernelEventPayload: Codable, Equatable, Sendable {
    case planned(KernelPlan)
    case stepStarted(stepID: UUID, attemptID: UUID)
    case stepFinished(attemptID: UUID, succeeded: Bool)
    case stepReopened(stepID: UUID, reason: String)
    case verificationRecorded(KernelEvidence)
    case decisionRecorded(String)
    case paused(reason: String)
    case resumed(modelIdentifier: String)
    case completed
}

public struct KernelEvent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let runID: UUID
    public let sequence: Int
    public let occurredAt: Date
    public let payload: KernelEventPayload

    public init(runID: UUID, sequence: Int, occurredAt: Date = .now, payload: KernelEventPayload) {
        schemaVersion = 1
        self.runID = runID
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.payload = payload
    }
}

public enum KernelError: Error, Equatable, Sendable {
    case executionBudgetExceeded
    case unsupportedSchema
    case invalidEventOrder
    case invalidPlan
    case invalidTransition
    case unresolvedAttempt
    case invalidEvidence
    case completionNotVerified
    case journalConflict
    case corruptJournal
    case journalLimitExceeded
}

/// Synchronous persistence keeps actor transitions free of suspension/reentrancy.
/// Append must be durable before returning and reject a stale sequence number.
public protocol KernelJournal: Sendable {
    func read() throws -> [KernelEvent]
    func append(_ event: KernelEvent) throws
}
