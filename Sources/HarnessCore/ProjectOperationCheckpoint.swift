import Foundation

public enum ResumableProjectOperation: String, Codable, Equatable, Sendable {
    case projectValidation
    case modelInference
    case fileEditInference
    case artifactPlanning
}

public struct ProjectOperationCheckpoint: Codable, Equatable, Sendable {
    public let operation: ResumableProjectOperation
    public let referenceID: UUID?
    public let startedAt: Date
    public let updatedAt: Date

    public init(
        operation: ResumableProjectOperation,
        referenceID: UUID? = nil,
        startedAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.operation = operation
        self.referenceID = referenceID
        self.startedAt = min(startedAt, updatedAt)
        self.updatedAt = max(startedAt, updatedAt)
    }
}

public enum ProjectOperationCheckpointWorkflow {
    public static func started(
        _ operation: ResumableProjectOperation,
        referenceID: UUID? = nil,
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        let existing = project.operationCheckpoint
        let resumesExisting = existing?.operation == operation
            && existing?.referenceID == referenceID
        project.operationCheckpoint = ProjectOperationCheckpoint(
            operation: operation,
            referenceID: referenceID,
            startedAt: resumesExisting
                ? existing?.startedAt ?? now
                : now,
            updatedAt: now
        )
    }

    public static func completed(
        _ operation: ResumableProjectOperation,
        in project: inout HarnessProject
    ) {
        guard project.operationCheckpoint?.operation == operation else { return }
        project.operationCheckpoint = nil
    }

    public static func discarded(in project: inout HarnessProject) {
        project.operationCheckpoint = nil
    }
}
