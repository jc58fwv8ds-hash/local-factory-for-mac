import Foundation

public struct BuildRepairTarget: Identifiable, Equatable, Sendable {
    public var id: String { relativePath }

    public let relativePath: String
    public let diagnostics: [BuildFailureDiagnostic]

    public init(
        relativePath: String,
        diagnostics: [BuildFailureDiagnostic]
    ) {
        self.relativePath = relativePath
        self.diagnostics = diagnostics
    }

    public var instruction: String {
        let details = diagnostics.prefix(4).map { diagnostic in
            let location = diagnostic.line.map { "行\($0)" } ?? "位置不明"
            return "- \(location): \(diagnostic.message)"
        }.joined(separator: "\n")
        return """
        次のビルドエラーを解消してください。
        対象ファイル: \(relativePath)
        \(details)
        変更範囲をこの1ファイルに限定し、既存の動作を保ってください。
        """
    }
}

public struct BuildRepairPlan: Equatable, Sendable {
    public let targets: [BuildRepairTarget]
    public let unresolvedErrorCount: Int

    public init(
        targets: [BuildRepairTarget],
        unresolvedErrorCount: Int
    ) {
        self.targets = targets
        self.unresolvedErrorCount = unresolvedErrorCount
    }
}

public struct BuildRepairProgress: Equatable, Sendable {
    public let plan: BuildRepairPlan
    public private(set) var currentTargetID: String?
    public private(set) var completedTargetIDs: Set<String>

    public init(
        plan: BuildRepairPlan,
        startingTargetID: String? = nil,
        completedTargetIDs: Set<String> = []
    ) {
        self.plan = plan
        let validStart = plan.targets.contains { $0.id == startingTargetID }
        currentTargetID = validStart ? startingTargetID : plan.targets.first?.id
        self.completedTargetIDs = completedTargetIDs.intersection(
            Set(plan.targets.map(\.id))
        )
    }

    public var currentTarget: BuildRepairTarget? {
        plan.targets.first { $0.id == currentTargetID }
    }

    public var nextTarget: BuildRepairTarget? {
        plan.targets.first {
            !completedTargetIDs.contains($0.id) && $0.id != currentTargetID
        }
    }

    public var completedCount: Int { completedTargetIDs.count }

    @discardableResult
    public mutating func select(relativePath: String) -> BuildRepairTarget? {
        guard let target = plan.targets.first(where: {
            $0.relativePath == relativePath
        }) else { return nil }
        currentTargetID = target.id
        return target
    }

    public mutating func markCompleted(relativePath: String) {
        guard let currentTarget, currentTarget.relativePath == relativePath else { return }
        completedTargetIDs.insert(currentTarget.id)
    }

    public mutating func markCurrentPending() {
        guard let currentTargetID else { return }
        completedTargetIDs.remove(currentTargetID)
    }
}

public enum BuildRepairPlanner {
    public static let maximumTargets = 8

    public static func plan(from analysis: BuildFailureAnalysis) -> BuildRepairPlan? {
        guard !analysis.diagnostics.isEmpty else { return nil }
        var orderedPaths: [String] = []
        var diagnosticsByPath: [String: [BuildFailureDiagnostic]] = [:]

        for diagnostic in analysis.diagnostics {
            if diagnosticsByPath[diagnostic.relativePath] == nil {
                orderedPaths.append(diagnostic.relativePath)
            }
            diagnosticsByPath[diagnostic.relativePath, default: []].append(diagnostic)
        }

        let selectedPaths = orderedPaths.prefix(maximumTargets)
        let targets = selectedPaths.compactMap { path -> BuildRepairTarget? in
            guard let diagnostics = diagnosticsByPath[path], !diagnostics.isEmpty else {
                return nil
            }
            return BuildRepairTarget(relativePath: path, diagnostics: diagnostics)
        }
        let omittedTargetCount = max(0, orderedPaths.count - targets.count)
        return BuildRepairPlan(
            targets: targets,
            unresolvedErrorCount: analysis.unresolvedErrorCount + omittedTargetCount
        )
    }
}
