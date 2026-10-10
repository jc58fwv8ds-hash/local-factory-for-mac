import Foundation

public struct RepairResumeState: Codable, Equatable, Sendable {
    public static let maximumTargets = 8

    public let createdAt: Date
    public let updatedAt: Date
    public let targetPaths: [String]
    public let completedPaths: [String]
    public let currentPath: String?

    public init(
        createdAt: Date = .now,
        updatedAt: Date = .now,
        targetPaths: [String],
        completedPaths: [String] = [],
        currentPath: String? = nil
    ) {
        let targets = Self.normalizedPaths(targetPaths)
        let targetSet = Set(targets)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.targetPaths = targets
        self.completedPaths = Self.normalizedPaths(completedPaths).filter(targetSet.contains)
        self.currentPath = currentPath.flatMap { targetSet.contains($0) ? $0 : nil }
    }

    public var completedCount: Int { completedPaths.count }
    public var pendingCount: Int { max(0, targetPaths.count - completedPaths.count) }

    private enum CodingKeys: String, CodingKey {
        case createdAt
        case updatedAt
        case targetPaths
        case completedPaths
        case currentPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            targetPaths: try container.decode([String].self, forKey: .targetPaths),
            completedPaths: try container.decodeIfPresent(
                [String].self,
                forKey: .completedPaths
            ) ?? [],
            currentPath: try container.decodeIfPresent(String.self, forKey: .currentPath)
        )
    }

    private static func normalizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path -> String? in
            guard seen.count < maximumTargets,
                  SourceRelativePathPolicy.isStructurallySafe(path),
                  seen.insert(path).inserted else { return nil }
            return path
        }
    }
}

public enum RepairResumeWorkflow {
    public static func started(
        plan: BuildRepairPlan,
        selectedTargetID: String,
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        let existing = project.repairResumeState
        let selectedPath = plan.targets.first { $0.id == selectedTargetID }?.relativePath
        project.repairResumeState = RepairResumeState(
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            targetPaths: (existing?.completedPaths ?? [])
                + plan.targets.map(\.relativePath),
            completedPaths: existing?.completedPaths ?? [],
            currentPath: selectedPath
        )
    }

    public static func updated(
        progress: BuildRepairProgress,
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        let existing = project.repairResumeState
        project.repairResumeState = RepairResumeState(
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            targetPaths: (existing?.completedPaths ?? [])
                + progress.plan.targets.map(\.relativePath),
            completedPaths: (existing?.completedPaths ?? [])
                + Array(progress.completedTargetIDs),
            currentPath: progress.currentTarget?.relativePath
        )
    }

    public static func validationCompleted(
        report: ProjectValidationReport,
        freshPlan: BuildRepairPlan?,
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        if report.succeeded {
            project.repairResumeState = nil
            return
        }
        guard let freshPlan else { return }
        let existing = project.repairResumeState
        let freshPaths = freshPlan.targets.map(\.relativePath)
        let completed = existing?.completedPaths ?? []
        let completedSet = Set(completed)
        let nextPath = freshPaths.first { !completedSet.contains($0) }
        project.repairResumeState = RepairResumeState(
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            targetPaths: completed + freshPaths,
            completedPaths: completed,
            currentPath: nextPath ?? existing?.currentPath
        )
    }

    public static func discarded(in project: inout HarnessProject) {
        project.repairResumeState = nil
    }
}
