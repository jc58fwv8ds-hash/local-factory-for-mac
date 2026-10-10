import Foundation
import HarnessCore

enum FileEditingChecks {
    static func run() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessFileEdit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makeFixture(at: rootURL)

        let editor = ProjectFileEditor()
        let files = try await editor.editableFiles(rootPath: rootURL.path)
        try expect(
            files.map(\.relativePath) == ["README.md", "Sources/App.swift"],
            "Editable file inventory must exclude dependencies, sensitive files, and symlinks"
        )
        print("✓ File editing inventory keeps strict source boundaries")

        let document = try await editor.load(
            rootPath: rootURL.path,
            relativePath: "Sources/App.swift"
        )
        let proposedContent = "let title = \"Harness\"\nprint(title)\n// Safe review\n"
        let proposal = try await editor.makeProposal(
            document: document,
            proposedContent: proposedContent
        )
        try expect(
            proposal.summary.addedLineCount == 2
                && proposal.summary.removedLineCount == 1
                && proposal.diffLines.contains(where: { $0.kind == .context }),
            "Line diff summary failed"
        )
        print("✓ File changes become a reviewable line diff")

        try await editor.apply(rootPath: rootURL.path, proposal: proposal)
        try expect(
            try String(contentsOf: appURL(in: rootURL), encoding: .utf8) == proposedContent,
            "Approved file proposal was not applied"
        )
        try await editor.revert(rootPath: rootURL.path, proposal: proposal)
        try expect(
            try String(contentsOf: appURL(in: rootURL), encoding: .utf8) == document.content,
            "Applied proposal was not reverted"
        )
        print("✓ Approved writes are atomic and immediately reversible")

        try await checkNewFileCreation(rootURL: rootURL, editor: editor)

        try Data("external change\n".utf8).write(to: appURL(in: rootURL), options: .atomic)
        do {
            try await editor.apply(rootPath: rootURL.path, proposal: proposal)
            throw CheckFailure(description: "Conflicting file write should fail")
        } catch let error as ProjectFileEditError {
            try expect(error == .changedSinceReview, "Unexpected conflict error: \(error)")
        }

        do {
            _ = try await editor.load(rootPath: rootURL.path, relativePath: "../outside.swift")
            throw CheckFailure(description: "Path traversal should fail")
        } catch let error as ProjectFileEditError {
            try expect(error == .invalidRelativePath, "Unexpected traversal error: \(error)")
        }

        do {
            _ = try await editor.makeProposal(document: document, proposedContent: " \n")
            throw CheckFailure(description: "Emptying a file should fail")
        } catch let error as ProjectFileEditError {
            try expect(error == .emptyContent, "Unexpected empty-content error: \(error)")
        }
        print("✓ Conflicts, path traversal, and destructive empty writes are rejected")

        try Data(document.content.utf8).write(to: appURL(in: rootURL), options: .atomic)
        try await checkGitCheckpoint(
            rootURL: rootURL,
            document: document,
            proposal: proposal,
            editor: editor
        )
        try await checkAIEditFormat(
            rootURL: rootURL,
            files: files,
            editor: editor,
            document: document
        )
        try checkProjectActivity(proposal: proposal)
    }

    private static func makeFixture(at rootURL: URL) throws {
        let sources = rootURL.appendingPathComponent("Sources", isDirectory: true)
        let dependencies = rootURL.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dependencies, withIntermediateDirectories: true)
        try Data("let title = \"Old\"\nprint(title)\n".utf8)
            .write(to: appURL(in: rootURL))
        try Data("# Harness\n".utf8).write(to: rootURL.appendingPathComponent("README.md"))
        try Data("token".utf8).write(to: rootURL.appendingPathComponent("credentials.json"))
        try Data("ignored".utf8).write(to: dependencies.appendingPathComponent("index.js"))
        try FileManager.default.createSymbolicLink(
            at: rootURL.appendingPathComponent("Linked.swift"),
            withDestinationURL: appURL(in: rootURL)
        )
    }

    private static func appURL(in rootURL: URL) -> URL {
        rootURL.appendingPathComponent("Sources/App.swift")
    }

    private static func checkAIEditFormat(
        rootURL: URL,
        files: [EditableSourceFile],
        editor: ProjectFileEditor,
        document: EditableSourceDocument
    ) async throws {
        let messages = try FileEditPromptBuilder.messages(
            document: document,
            instruction: "タイトルを更新"
        )
        let rawJSON = #"{"content":"let title = \"New\"\n"}"#
        let fencedJSON = "```json\n\(rawJSON)\n```"
        try expect(
            messages.count == 2
                && messages[1].content.contains(document.relativePath)
                && FileEditResponseParser.proposedContent(from: rawJSON) == "let title = \"New\"\n"
                && FileEditResponseParser.proposedContent(from: fencedJSON) == "let title = \"New\"\n",
            "AI file edit prompt or JSON parser failed"
        )
        let references = await FileCreationReferenceContext.collect(
            rootPath: rootURL.path,
            targetPath: "Sources/NewFeature.swift",
            files: files,
            editor: editor
        )
        let creationMessages = try FileEditPromptBuilder.creationMessages(
            relativePath: "Sources/NewFeature.swift",
            instruction: "安全な値型を追加",
            referenceDocuments: references
        )
        try expect(
            creationMessages.count == 2
                && creationMessages[0].content.contains("新規ファイル1件")
                && creationMessages[1].content.contains("Sources/NewFeature.swift")
                && creationMessages[1].content.contains("Sources/App.swift")
                && creationMessages[1].content.contains("HARNESS_REFERENCE_SOURCE"),
            "AI new-file prompt boundary failed"
        )
        print("✓ Local AI file edits use bounded project references and a structured response")
    }

    private static func checkNewFileCreation(
        rootURL: URL,
        editor: ProjectFileEditor
    ) async throws {
        let relativePath = "Sources/NewFeature.swift"
        let content = "struct NewFeature {}\n"
        let proposal = try await editor.makeCreationProposal(
            rootPath: rootURL.path,
            relativePath: relativePath,
            proposedContent: content
        )
        try expect(
            proposal.operation == .creation
                && proposal.originalContent.isEmpty
                && proposal.summary.removedLineCount == 0
                && proposal.diffLines.allSatisfy { $0.kind == .addition },
            "New-file proposal must be an additions-only review"
        )

        try await editor.apply(rootPath: rootURL.path, proposal: proposal)
        let fileURL = rootURL.appendingPathComponent(relativePath)
        try expect(
            try String(contentsOf: fileURL, encoding: .utf8) == content,
            "Approved new file was not created"
        )
        do {
            try await editor.apply(rootPath: rootURL.path, proposal: proposal)
            throw CheckFailure(description: "New-file apply must never overwrite")
        } catch let error as ProjectFileEditError {
            try expect(error == .fileAlreadyExists, "Unexpected creation conflict: \(error)")
        }

        try Data("external replacement\n".utf8).write(to: fileURL, options: .atomic)
        do {
            try await editor.revert(rootPath: rootURL.path, proposal: proposal)
            throw CheckFailure(description: "Changed created file must not be deleted")
        } catch let error as ProjectFileEditError {
            try expect(error == .changedSinceReview, "Unexpected creation revert conflict: \(error)")
        }
        try Data(content.utf8).write(to: fileURL, options: .atomic)
        try await editor.revert(rootPath: rootURL.path, proposal: proposal)
        try expect(!FileManager.default.fileExists(atPath: fileURL.path), "Creation revert failed")

        for invalidPath in [
            "../Outside.swift",
            " Sources/New.swift",
            "Sources/Bad\n.swift",
            "node_modules/Generated.js",
            "Sources/private_key.swift",
            "Missing/New.swift"
        ] {
            do {
                _ = try await editor.makeCreationProposal(
                    rootPath: rootURL.path,
                    relativePath: invalidPath,
                    proposedContent: content
                )
                throw CheckFailure(description: "Unsafe new-file path was accepted: \(invalidPath)")
            } catch is ProjectFileEditError {}
        }
        let brokenLink = rootURL.appendingPathComponent("Sources/Broken.swift")
        try FileManager.default.createSymbolicLink(
            at: brokenLink,
            withDestinationURL: rootURL.appendingPathComponent("MissingTarget.swift")
        )
        do {
            _ = try await editor.makeCreationProposal(
                rootPath: rootURL.path,
                relativePath: "Sources/Broken.swift",
                proposedContent: content
            )
            throw CheckFailure(description: "Broken symlink target was accepted for creation")
        } catch let error as ProjectFileEditError {
            try expect(error == .fileAlreadyExists, "Unexpected symlink conflict: \(error)")
        }
        print("✓ New files require additions-only review and never overwrite existing content")
    }

    private static func checkGitCheckpoint(
        rootURL: URL,
        document: EditableSourceDocument,
        proposal: FileChangeProposal,
        editor: ProjectFileEditor
    ) async throws {
        try runGit(["init", rootURL.path])
        let service = GitCheckpointService(fileEditor: editor)
        let creationProposal = try await editor.makeCreationProposal(
            rootPath: rootURL.path,
            relativePath: "Sources/CheckpointFree.swift",
            proposedContent: "struct CheckpointFree {}\n"
        )
        let creationCheckpoint = try await service.create(
            rootPath: rootURL.path,
            proposal: creationProposal
        )
        try expect(
            creationCheckpoint == nil,
            "New-file proposals must not create misleading blob restore points"
        )
        let checkpoint = try require(
            try await service.create(rootPath: rootURL.path, proposal: proposal)
        )
        try expect(
            checkpoint.relativePath == proposal.relativePath
                && checkpoint.originalObjectID.count == 40
                && checkpoint.appliedObjectID.count == 40,
            "Git checkpoint metadata is invalid"
        )

        try await editor.apply(rootPath: rootURL.path, proposal: proposal)
        _ = try await service.restore(checkpoint)
        try expect(
            try String(contentsOf: appURL(in: rootURL), encoding: .utf8) == document.content,
            "Git checkpoint did not restore the original blob"
        )
        await service.discard(checkpoint)

        let secondCheckpoint = try require(
            try await service.create(rootPath: rootURL.path, proposal: proposal)
        )
        try await editor.apply(rootPath: rootURL.path, proposal: proposal)
        try Data("changed after checkpoint\n".utf8)
            .write(to: appURL(in: rootURL), options: .atomic)
        do {
            _ = try await service.restore(secondCheckpoint)
            throw CheckFailure(description: "Stale Git checkpoint restore should fail")
        } catch let error as GitCheckpointError {
            try expect(
                error == .changedSinceCheckpoint,
                "Unexpected Git restore conflict: \(error)"
            )
        }
        await service.discard(secondCheckpoint)
        try Data(document.content.utf8).write(to: appURL(in: rootURL), options: .atomic)
        print("✓ Git blob checkpoints restore safely and reject later changes")
    }

    private static func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "Git fixture setup failed")
    }

    private static func checkProjectActivity(proposal: FileChangeProposal) throws {
        var project = HarnessProject.starter
        let checkpoint = GitFileCheckpoint(
            sourceRootPath: "/tmp/source",
            repositoryRootPath: "/tmp/source",
            relativePath: proposal.relativePath,
            originalObjectID: String(repeating: "a", count: 40),
            appliedObjectID: String(repeating: "b", count: 40)
        )
        ProjectFileChangeWorkflow.applied(
            proposal: proposal,
            checkpoint: checkpoint,
            in: &project
        )
        try expect(
            project.activity.first?.kind == .change
                && project.currentActivity.contains(proposal.relativePath)
                && project.fileCheckpoints.first == checkpoint,
            "Applied file change activity was not recorded"
        )
        var expiredCheckpoint: GitFileCheckpoint?
        for index in 0..<20 {
            let nextCheckpoint = GitFileCheckpoint(
                sourceRootPath: "/tmp/source",
                repositoryRootPath: "/tmp/source",
                relativePath: "Sources/File\(index).swift",
                originalObjectID: String(repeating: "c", count: 40),
                appliedObjectID: String(repeating: "d", count: 40)
            )
            expiredCheckpoint = ProjectFileChangeWorkflow.applied(
                proposal: proposal,
                checkpoint: nextCheckpoint,
                in: &project
            )
        }
        try expect(
            project.fileCheckpoints.count == 20 && expiredCheckpoint == checkpoint,
            "Checkpoint history must evict its oldest entry at the fixed limit"
        )
        ProjectFileChangeWorkflow.reverted(
            proposal: proposal,
            checkpoint: project.fileCheckpoints[0],
            in: &project
        )
        try expect(
            project.activity.first?.kind == .verification
                && project.fileCheckpoints.count == 19,
            "Reverted file change activity was not recorded"
        )
        print("✓ Applied and reverted file changes update project activity consistently")
    }
}
