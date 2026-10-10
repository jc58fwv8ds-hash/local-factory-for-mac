import Foundation
import HarnessCore

/// Private, bounded recovery material. No automatic overwrite/rollback is authorized by it.
struct FileEditCheckpoint: Encodable {
    let schemaVersion = 1
    let rootPath: String
    let proposalID: UUID
    let relativePath: String
    let operation: String
    let reverting: Bool
    let originalContent: String
    let proposedContent: String

    static func save(proposal: FileChangeProposal, reverting: Bool, root: URL, directory: URL) throws -> String {
        guard proposal.originalContent.utf8.count <= ProjectFileEditor.maximumFileBytes,
              proposal.proposedContent.utf8.count <= ProjectFileEditor.maximumFileBytes else {
            throw ProjectFileEditError.fileTooLarge(maximumBytes: ProjectFileEditor.maximumFileBytes)
        }
        let checkpoint = Self(rootPath: root.path, proposalID: proposal.id, relativePath: proposal.relativePath,
            operation: proposal.operation.rawValue, reverting: reverting,
            originalContent: proposal.originalContent, proposedContent: proposal.proposedContent)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(checkpoint)
        let url = directory.appendingPathComponent("checkpoint.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        return "checkpoint.json#sha256=\(ValidationSourceIdentity.hash(data))"
    }
}
