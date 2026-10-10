import Foundation

public enum ToolAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case readFiles
    case writeFiles
    case runBuild
    case runTests
    case accessNetwork
    case installModels
    case removeModels
    case deleteFiles
    case changeSigning
    case publish

    public var id: String { rawValue }
}

public enum ApprovalRequirement: String, Codable, Sendable {
    case automatic
    case askEveryTime
}

public struct PermissionPolicy: Codable, Equatable, Sendable {
    public var alwaysAsk: Set<ToolAction>

    public init(
        alwaysAsk: Set<ToolAction> = [
            .writeFiles,
            .installModels,
            .removeModels,
            .deleteFiles,
            .changeSigning,
            .publish
        ]
    ) {
        self.alwaysAsk = alwaysAsk
    }

    public func requirement(for action: ToolAction) -> ApprovalRequirement {
        alwaysAsk.contains(action) ? .askEveryTime : .automatic
    }
}
