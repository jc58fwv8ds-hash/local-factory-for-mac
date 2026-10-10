import Foundation

public enum ProjectLifecycle: String, Codable, CaseIterable, Sendable {
    case active
    case archived
    case trashed
}

public enum ProjectOrigin: String, Codable, Sendable {
    case createdInHarness
    case imported
}

public struct ProjectRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID { project.id }
    public var project: HarnessProject
    public var lifecycle: ProjectLifecycle
    public var origin: ProjectOrigin
    public var sourceLocation: String?
    public var sourceInspection: SourceInspection?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastOpenedAt: Date

    public init(
        project: HarnessProject,
        lifecycle: ProjectLifecycle = .active,
        origin: ProjectOrigin = .createdInHarness,
        sourceLocation: String? = nil,
        sourceInspection: SourceInspection? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastOpenedAt: Date = .now
    ) {
        self.project = project
        self.lifecycle = lifecycle
        self.origin = origin
        self.sourceLocation = sourceLocation
        self.sourceInspection = sourceInspection
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
    }
}

public struct ProjectLibrary: Codable, Equatable, Sendable {
    public var records: [ProjectRecord]
    public var selectedProjectID: UUID?
    public var modelAcquisitionCheckpoint: ModelAcquisitionCheckpoint?

    public init(
        records: [ProjectRecord],
        selectedProjectID: UUID? = nil,
        modelAcquisitionCheckpoint: ModelAcquisitionCheckpoint? = nil
    ) {
        self.records = records
        self.selectedProjectID = selectedProjectID ?? records.first(where: { $0.lifecycle == .active })?.id
        self.modelAcquisitionCheckpoint = modelAcquisitionCheckpoint
        normalizeSelection()
    }

    public var activeRecords: [ProjectRecord] {
        records
            .filter { $0.lifecycle == .active }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    public var archivedRecords: [ProjectRecord] {
        records
            .filter { $0.lifecycle == .archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public var trashedRecords: [ProjectRecord] {
        records
            .filter { $0.lifecycle == .trashed }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public var selectedRecord: ProjectRecord? {
        guard let selectedProjectID else { return nil }
        return records.first { $0.id == selectedProjectID && $0.lifecycle == .active }
    }

    public mutating func add(_ record: ProjectRecord, select: Bool = true) {
        records.append(record)
        if select {
            selectedProjectID = record.id
        }
    }

    public mutating func select(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id && $0.lifecycle == .active }) else {
            return
        }
        records[index].lastOpenedAt = .now
        selectedProjectID = id
    }

    public mutating func archive(_ id: UUID) {
        transition(id, to: .archived)
    }

    public mutating func moveToTrash(_ id: UUID) {
        transition(id, to: .trashed)
    }

    public mutating func restore(_ id: UUID) {
        transition(id, to: .active)
    }

    public mutating func removeFromLibrary(_ id: UUID) {
        records.removeAll { $0.id == id }
        normalizeSelection()
    }

    private mutating func transition(_ id: UUID, to lifecycle: ProjectLifecycle) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].lifecycle = lifecycle
        records[index].updatedAt = .now
        if lifecycle == .active {
            records[index].lastOpenedAt = .now
            selectedProjectID = id
        }
        normalizeSelection()
    }

    private mutating func normalizeSelection() {
        let selectionIsActive = selectedProjectID.flatMap { selectedID in
            records.first { $0.id == selectedID && $0.lifecycle == .active }
        } != nil

        if !selectionIsActive {
            selectedProjectID = activeRecords.first?.id
        }
    }
}

public extension ProjectLibrary {
    static let starter = ProjectLibrary(
        records: [ProjectRecord(project: .starter)]
    )
}
