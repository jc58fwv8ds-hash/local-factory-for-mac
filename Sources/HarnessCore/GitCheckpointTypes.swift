import Foundation

public struct GitFileCheckpoint: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let sourceRootPath: String
    public let repositoryRootPath: String
    public let relativePath: String
    public let originalObjectID: String
    public let appliedObjectID: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        sourceRootPath: String,
        repositoryRootPath: String,
        relativePath: String,
        originalObjectID: String,
        appliedObjectID: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceRootPath = sourceRootPath
        self.repositoryRootPath = repositoryRootPath
        self.relativePath = relativePath
        self.originalObjectID = originalObjectID
        self.appliedObjectID = appliedObjectID
    }

    public var shortObjectID: String {
        String(originalObjectID.prefix(10))
    }
}

public enum GitCheckpointError: LocalizedError, Equatable, Sendable {
    case gitUnavailable
    case commandFailed(String)
    case invalidObject
    case changedSinceCheckpoint

    public var errorDescription: String? {
        switch self {
        case .gitUnavailable: "Gitを実行できません。Command Line Toolsを確認してください。"
        case let .commandFailed(message): "Git復元ポイントを作成できませんでした：\(message)"
        case .invalidObject: "Git復元ポイントの内容を読み取れません。"
        case .changedSinceCheckpoint:
            "復元ポイント作成後にファイルが変更されています。現在の内容は上書きしません。"
        }
    }
}

public protocol GitCheckpointing: Sendable {
    func create(
        rootPath: String,
        proposal: FileChangeProposal
    ) async throws -> GitFileCheckpoint?
    func restore(_ checkpoint: GitFileCheckpoint) async throws -> FileChangeProposal
    func discard(_ checkpoint: GitFileCheckpoint) async
}
