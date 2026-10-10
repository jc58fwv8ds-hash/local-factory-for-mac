import Foundation

public actor GitCheckpointService: GitCheckpointing {
    private struct CommandResult {
        let status: Int32
        let data: Data

        var text: String {
            String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    private let fileManager: FileManager
    private let fileEditor: any ProjectFileEditing

    public init(
        fileManager: FileManager = .default,
        fileEditor: any ProjectFileEditing = ProjectFileEditor()
    ) {
        self.fileManager = fileManager
        self.fileEditor = fileEditor
    }

    public func create(
        rootPath: String,
        proposal: FileChangeProposal
    ) async throws -> GitFileCheckpoint? {
        guard proposal.operation == .update else { return nil }
        let sourceRoot = URL(fileURLWithPath: rootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let repositoryResult = try runGit(
            arguments: ["-C", sourceRoot.path, "rev-parse", "--show-toplevel"]
        )
        guard repositoryResult.status == 0 else { return nil }

        let repositoryRoot = URL(fileURLWithPath: repositoryResult.text)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let originalObjectID = try writeBlob(
            proposal.originalContent,
            repositoryRoot: repositoryRoot
        )
        let appliedObjectID = try writeBlob(
            proposal.proposedContent,
            repositoryRoot: repositoryRoot
        )
        let checkpointID = UUID()
        let refBase = "refs/harness/checkpoints/\(checkpointID.uuidString.lowercased())"

        do {
            try updateRef(
                "\(refBase)/original",
                objectID: originalObjectID,
                repositoryRoot: repositoryRoot
            )
            try updateRef(
                "\(refBase)/applied",
                objectID: appliedObjectID,
                repositoryRoot: repositoryRoot
            )
        } catch {
            deleteRef("\(refBase)/original", repositoryRoot: repositoryRoot)
            deleteRef("\(refBase)/applied", repositoryRoot: repositoryRoot)
            throw error
        }

        return GitFileCheckpoint(
            id: checkpointID,
            sourceRootPath: sourceRoot.path,
            repositoryRootPath: repositoryRoot.path,
            relativePath: proposal.relativePath,
            originalObjectID: originalObjectID,
            appliedObjectID: appliedObjectID
        )
    }

    public func restore(_ checkpoint: GitFileCheckpoint) async throws -> FileChangeProposal {
        let currentDocument = try await fileEditor.load(
            rootPath: checkpoint.sourceRootPath,
            relativePath: checkpoint.relativePath
        )
        let currentObjectID = try hashBlob(
            currentDocument.content,
            repositoryRoot: URL(fileURLWithPath: checkpoint.repositoryRootPath)
        )
        guard currentObjectID == checkpoint.appliedObjectID else {
            throw GitCheckpointError.changedSinceCheckpoint
        }

        let originalContent = try readBlob(
            checkpoint.originalObjectID,
            repositoryRoot: URL(fileURLWithPath: checkpoint.repositoryRootPath)
        )
        let proposal = try await fileEditor.makeProposal(
            document: currentDocument,
            proposedContent: originalContent
        )
        try await fileEditor.apply(
            rootPath: checkpoint.sourceRootPath,
            proposal: proposal
        )
        return proposal
    }

    public func discard(_ checkpoint: GitFileCheckpoint) {
        let repositoryRoot = URL(fileURLWithPath: checkpoint.repositoryRootPath)
        let refBase = "refs/harness/checkpoints/\(checkpoint.id.uuidString.lowercased())"
        deleteRef("\(refBase)/original", repositoryRoot: repositoryRoot)
        deleteRef("\(refBase)/applied", repositoryRoot: repositoryRoot)
    }

    private func writeBlob(_ content: String, repositoryRoot: URL) throws -> String {
        let result = try runGit(
            arguments: ["-C", repositoryRoot.path, "hash-object", "-w", "--stdin"],
            input: Data(content.utf8)
        )
        guard result.status == 0, Self.isObjectID(result.text) else {
            throw GitCheckpointError.commandFailed(result.text)
        }
        return result.text
    }

    private func hashBlob(_ content: String, repositoryRoot: URL) throws -> String {
        let result = try runGit(
            arguments: ["-C", repositoryRoot.path, "hash-object", "--stdin"],
            input: Data(content.utf8)
        )
        guard result.status == 0, Self.isObjectID(result.text) else {
            throw GitCheckpointError.commandFailed(result.text)
        }
        return result.text
    }

    private func readBlob(_ objectID: String, repositoryRoot: URL) throws -> String {
        guard Self.isObjectID(objectID) else { throw GitCheckpointError.invalidObject }
        let result = try runGit(
            arguments: ["-C", repositoryRoot.path, "cat-file", "blob", objectID]
        )
        guard result.status == 0,
              !result.data.contains(0),
              let content = String(data: result.data, encoding: .utf8) else {
            throw GitCheckpointError.invalidObject
        }
        return content
    }

    private func updateRef(
        _ ref: String,
        objectID: String,
        repositoryRoot: URL
    ) throws {
        let result = try runGit(
            arguments: ["-C", repositoryRoot.path, "update-ref", ref, objectID]
        )
        guard result.status == 0 else {
            throw GitCheckpointError.commandFailed(result.text)
        }
    }

    private func deleteRef(_ ref: String, repositoryRoot: URL) {
        _ = try? runGit(
            arguments: ["-C", repositoryRoot.path, "update-ref", "-d", ref]
        )
    }

    private func runGit(arguments: [String], input: Data? = nil) throws -> CommandResult {
        guard fileManager.isExecutableFile(atPath: "/usr/bin/git") else {
            throw GitCheckpointError.gitUnavailable
        }

        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarnessGit-\(UUID().uuidString).log")
        let inputURL = input.map { _ in
            fileManager.temporaryDirectory
                .appendingPathComponent("HarnessGit-\(UUID().uuidString).input")
        }
        defer {
            try? fileManager.removeItem(at: outputURL)
            if let inputURL { try? fileManager.removeItem(at: inputURL) }
        }

        fileManager.createFile(atPath: outputURL.path, contents: nil)
        if let input, let inputURL { try input.write(to: inputURL, options: .atomic) }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let inputHandle = try inputURL.map(FileHandle.init(forReadingFrom:))
        defer {
            try? outputHandle.close()
            try? inputHandle?.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        process.standardInput = inputHandle
        do {
            try process.run()
        } catch {
            throw GitCheckpointError.gitUnavailable
        }
        process.waitUntilExit()
        try outputHandle.synchronize()
        return CommandResult(
            status: process.terminationStatus,
            data: try Data(contentsOf: outputURL)
        )
    }

    private static func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy { $0.isHexDigit }
    }
}
