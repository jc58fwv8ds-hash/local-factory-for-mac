import Foundation

public struct ArtifactCreationTarget: Identifiable, Codable, Equatable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let instruction: String

    public init(relativePath: String, instruction: String) {
        self.relativePath = relativePath
        self.instruction = String(
            instruction.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800)
        )
    }
}

public struct ArtifactCreationPlan: Codable, Equatable, Sendable {
    public static let maximumTargets = 8
    public static let maximumInstructionCharacters = 1_200

    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public let instruction: String
    public let targets: [ArtifactCreationTarget]
    public private(set) var completedPaths: [String]
    public private(set) var currentPath: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        updatedAt: Date = .now,
        instruction: String,
        targets: [ArtifactCreationTarget],
        completedPaths: [String] = [],
        currentPath: String? = nil
    ) {
        var seen = Set<String>()
        let safeTargets = targets.compactMap { target -> ArtifactCreationTarget? in
            let comparisonPath = target.relativePath.lowercased()
            guard seen.count < Self.maximumTargets,
                  SourceRelativePathPolicy.isAllowedCreationPath(target.relativePath),
                  !target.instruction.isEmpty,
                  seen.insert(comparisonPath).inserted else { return nil }
            return ArtifactCreationTarget(
                relativePath: target.relativePath,
                instruction: target.instruction
            )
        }
        let targetPaths = Set(safeTargets.map(\.relativePath))
        var completedSeen = Set<String>()
        let safeCompleted = completedPaths.filter {
            targetPaths.contains($0) && completedSeen.insert($0).inserted
        }

        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.instruction = String(
            instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Self.maximumInstructionCharacters)
        )
        self.targets = safeTargets
        self.completedPaths = safeCompleted
        let decodedCurrent = currentPath.flatMap { path in
            targetPaths.contains(path) && !safeCompleted.contains(path) ? path : nil
        }
        self.currentPath = decodedCurrent
            ?? safeTargets.first { !safeCompleted.contains($0.relativePath) }?.relativePath
            ?? safeTargets.last?.relativePath
    }

    public var currentTarget: ArtifactCreationTarget? {
        targets.first { $0.relativePath == currentPath }
    }

    public var nextTarget: ArtifactCreationTarget? {
        targets.first {
            !completedPaths.contains($0.relativePath) && $0.relativePath != currentPath
        }
    }

    public var completedCount: Int { completedPaths.count }
    public var isFullyApplied: Bool { !targets.isEmpty && completedCount == targets.count }

    public mutating func markCompleted(relativePath: String, now: Date = .now) {
        guard targets.contains(where: { $0.relativePath == relativePath }),
              !completedPaths.contains(relativePath) else { return }
        completedPaths.append(relativePath)
        updatedAt = now
    }

    public mutating func markPending(relativePath: String, now: Date = .now) {
        completedPaths.removeAll { $0 == relativePath }
        currentPath = relativePath
        updatedAt = now
    }

    @discardableResult
    public mutating func advance(now: Date = .now) -> ArtifactCreationTarget? {
        guard let nextTarget else { return nil }
        currentPath = nextTarget.relativePath
        updatedAt = now
        return nextTarget
    }

    public mutating func resumePendingTarget(now: Date = .now) {
        guard let currentPath, completedPaths.contains(currentPath), let nextTarget else { return }
        self.currentPath = nextTarget.relativePath
        updatedAt = now
    }
}

extension ArtifactCreationPlan {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, instruction, targets, completedPaths, currentPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            instruction: try container.decode(String.self, forKey: .instruction),
            targets: try container.decode([ArtifactCreationTarget].self, forKey: .targets),
            completedPaths: try container.decodeIfPresent(
                [String].self,
                forKey: .completedPaths
            ) ?? [],
            currentPath: try container.decodeIfPresent(String.self, forKey: .currentPath)
        )
    }
}
