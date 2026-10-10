import Foundation

public struct ModelAcquisitionRequest: Codable, Equatable, Sendable {
    public let catalogEntryID: String
    public let displayName: String
    public let estimatedSizeGB: Double
    public let runtime: RuntimeKind
    public let modelIdentifier: String

    public init?(
        entry: ModelCatalogEntry,
        runtime: RuntimeKind
    ) {
        guard let identifier = entry.identifier(for: runtime)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !identifier.isEmpty else {
            return nil
        }
        self.catalogEntryID = entry.id
        self.displayName = entry.displayName
        self.estimatedSizeGB = max(0, entry.estimatedSizeGB)
        self.runtime = runtime
        self.modelIdentifier = identifier
    }
}

public struct ModelAcquisitionCheckpoint: Codable, Equatable, Sendable {
    public let request: ModelAcquisitionRequest
    public let startedAt: Date
    public let updatedAt: Date

    public init(
        request: ModelAcquisitionRequest,
        startedAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.request = request
        self.startedAt = min(startedAt, updatedAt)
        self.updatedAt = max(startedAt, updatedAt)
    }
}

public enum ModelAcquisitionCheckpointWorkflow {
    public static func refreshed(
        _ checkpoint: ModelAcquisitionCheckpoint?,
        catalog: [ModelCatalogEntry]
    ) -> ModelAcquisitionCheckpoint? {
        guard let checkpoint,
              let entry = catalog.first(where: { $0.id == checkpoint.request.catalogEntryID }),
              let currentRequest = ModelAcquisitionRequest(
                entry: entry,
                runtime: checkpoint.request.runtime
              ),
              currentRequest != checkpoint.request else {
            return checkpoint
        }
        return ModelAcquisitionCheckpoint(
            request: currentRequest,
            startedAt: checkpoint.startedAt,
            updatedAt: checkpoint.updatedAt
        )
    }

    public static func started(
        _ request: ModelAcquisitionRequest,
        in checkpoint: inout ModelAcquisitionCheckpoint?,
        now: Date = .now
    ) {
        checkpoint = ModelAcquisitionCheckpoint(
            request: request,
            startedAt: checkpoint?.request == request
                ? checkpoint?.startedAt ?? now
                : now,
            updatedAt: now
        )
    }

    public static func completed(
        _ request: ModelAcquisitionRequest,
        in checkpoint: inout ModelAcquisitionCheckpoint?
    ) {
        guard checkpoint?.request == request else { return }
        checkpoint = nil
    }

    public static func discarded(
        in checkpoint: inout ModelAcquisitionCheckpoint?
    ) {
        checkpoint = nil
    }
}
