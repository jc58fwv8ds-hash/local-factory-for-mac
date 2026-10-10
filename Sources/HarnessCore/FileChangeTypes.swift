import Foundation

public struct EditableSourceFile: Identifiable, Equatable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let byteCount: Int

    public init(relativePath: String, byteCount: Int) {
        self.relativePath = relativePath
        self.byteCount = byteCount
    }
}

public struct EditableSourceDocument: Equatable, Sendable {
    public let relativePath: String
    public let content: String

    public init(relativePath: String, content: String) {
        self.relativePath = relativePath
        self.content = content
    }
}

public enum FileDiffLineKind: String, Equatable, Sendable {
    case context
    case removal
    case addition
}

public struct FileDiffLine: Equatable, Sendable {
    public let kind: FileDiffLineKind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let text: String

    public init(
        kind: FileDiffLineKind,
        oldLineNumber: Int?,
        newLineNumber: Int?,
        text: String
    ) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
    }
}

public struct FileChangeSummary: Equatable, Sendable {
    public let addedLineCount: Int
    public let removedLineCount: Int

    public init(addedLineCount: Int, removedLineCount: Int) {
        self.addedLineCount = addedLineCount
        self.removedLineCount = removedLineCount
    }
}

public enum FileChangeOperation: String, Equatable, Sendable {
    case update
    case creation
}

public struct FileChangeProposal: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let operation: FileChangeOperation
    public let relativePath: String
    public let originalContent: String
    public let proposedContent: String
    public let diffLines: [FileDiffLine]
    public let summary: FileChangeSummary
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        operation: FileChangeOperation = .update,
        relativePath: String,
        originalContent: String,
        proposedContent: String,
        diffLines: [FileDiffLine],
        summary: FileChangeSummary,
        createdAt: Date = .now
    ) {
        self.id = id
        self.operation = operation
        self.relativePath = relativePath
        self.originalContent = originalContent
        self.proposedContent = proposedContent
        self.diffLines = diffLines
        self.summary = summary
        self.createdAt = createdAt
    }
}

public struct AppliedFileChange: Equatable, Sendable {
    public let proposal: FileChangeProposal
    public let checkpoint: GitFileCheckpoint?

    public init(proposal: FileChangeProposal, checkpoint: GitFileCheckpoint?) {
        self.proposal = proposal
        self.checkpoint = checkpoint
    }
}

public enum ProjectFileEditError: LocalizedError, Equatable, Sendable {
    case sourceMissing
    case sourceNotDirectory
    case invalidRelativePath
    case fileNotEditable
    case fileTooLarge(maximumBytes: Int)
    case unreadableText
    case noChanges
    case emptyContent
    case changedSinceReview
    case fileAlreadyExists
    case parentDirectoryMissing

    public var errorDescription: String? {
        switch self {
        case .sourceMissing: "接続したソースフォルダが見つかりません。"
        case .sourceNotDirectory: "接続したソースはフォルダではありません。"
        case .invalidRelativePath: "ソースフォルダ外のパスは編集できません。"
        case .fileNotEditable: "このファイル形式またはシンボリックリンクは編集できません。"
        case let .fileTooLarge(maximumBytes):
            "安全のため\(maximumBytes / 1_000)KBを超えるファイルは編集できません。"
        case .unreadableText: "UTF-8テキストとして読み取れません。"
        case .noChanges: "変更内容がありません。"
        case .emptyContent: "誤操作防止のため、ファイルを空にする変更は適用できません。"
        case .changedSinceReview:
            "レビュー後にファイルが変更されました。再読み込みして差分を確認してください。"
        case .fileAlreadyExists:
            "同名のファイルがすでにあります。既存ファイルとして選び直してください。"
        case .parentDirectoryMissing:
            "作成先のフォルダが見つかりません。既存のフォルダ内を指定してください。"
        }
    }
}

public protocol ProjectFileEditing: Sendable {
    func editableFiles(rootPath: String) async throws -> [EditableSourceFile]
    func load(rootPath: String, relativePath: String) async throws -> EditableSourceDocument
    func makeProposal(
        document: EditableSourceDocument,
        proposedContent: String
    ) async throws -> FileChangeProposal
    func makeCreationProposal(
        rootPath: String,
        relativePath: String,
        proposedContent: String
    ) async throws -> FileChangeProposal
    func validateCreationPath(rootPath: String, relativePath: String) async throws
    func apply(rootPath: String, proposal: FileChangeProposal) async throws
    func revert(rootPath: String, proposal: FileChangeProposal) async throws
}
