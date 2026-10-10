import Foundation

public enum WorkspaceLoadSource: Sendable, Equatable {
    case none
    case primary
    case backup
}

public struct WorkspaceLoadResult: Sendable, Equatable {
    public let library: ProjectLibrary?
    public let source: WorkspaceLoadSource

    public init(library: ProjectLibrary?, source: WorkspaceLoadSource) {
        self.library = library
        self.source = source
    }

    public var recoveredFromBackup: Bool {
        source == .backup
    }
}

public enum WorkspaceRepositoryError: LocalizedError, Sendable {
    case noRecoverableWorkspace
    case refusingToOverwriteCorruptWorkspace

    public var errorDescription: String? {
        switch self {
        case .noRecoverableWorkspace:
            "ワークスペース本体とバックアップのどちらも読み取れません。"
        case .refusingToOverwriteCorruptWorkspace:
            "復元できるワークスペースがないため、破損ファイルの上書きを停止しました。"
        }
    }
}
