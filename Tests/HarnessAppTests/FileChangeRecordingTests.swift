import Foundation
import HarnessCore
import HarnessExecution
import Testing
@testable import HarnessApp

@MainActor
struct FileChangeRecordingTests {
    @Test func preparingReviewDoesNotWriteAndApprovedApplyKeepsUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let editor = RecordedProjectFileEditor(directory: fixture.runs)
        let checkpoints = Checkpoints()
        let session = fixture.session(editor: editor, checkpoints: checkpoints)
        await session.select("Example.swift")
        session.updateProposedContent("let value = 2")
        await session.prepareReview()
        #expect(session.proposal != nil && !session.isApplied)
        #expect(!FileManager.default.fileExists(atPath: fixture.runs.path))
        #expect(await checkpoints.created == 0)
        #expect(await session.applyProposal() != nil)
        #expect(session.isApplied && !session.hasUnresolvedEdit)
        #expect(await checkpoints.created == 1)
        #expect(await editor.lastRunDirectory != nil)
        #expect(await session.revertAppliedProposal() != nil)
        #expect(!session.isApplied && session.appliedChange == nil)
        #expect(await checkpoints.discarded == 1)
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "let value = 1")
    }

    @Test(arguments: [false, true])
    func uncertainEditKeepsCheckpointAndDisablesRepeat(reverting: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let editor = RecordedProjectFileEditor(directory: fixture.runs)
        let checkpoints = Checkpoints()
        let first = fixture.session(editor: editor, checkpoints: checkpoints)
        await first.select("Example.swift")
        first.updateProposedContent("let value = 2")
        await first.prepareReview()
        #expect(await first.applyProposal() != nil)
        let run = try #require(await editor.lastRunDirectory)
        try Data("broken".utf8).write(to: run.appendingPathComponent("events/00000001.json"))
        let session: FileChangeSession
        if reverting {
            session = first
            #expect(await session.revertAppliedProposal() == nil)
        } else {
            session = fixture.session(editor: RecordedProjectFileEditor(directory: fixture.runs), checkpoints: checkpoints)
            await session.select("Example.swift")
            session.updateProposedContent("let value = 3")
            await session.prepareReview()
            #expect(await session.applyProposal() == nil)
        }
        #expect(session.hasUnresolvedEdit && !session.canAskAI && !session.canReview)
        #expect(session.appliedChange?.checkpoint != nil)
        #expect(session.errorMessage?.contains("再適用を止めました") == true)
        #expect(await checkpoints.discarded == 0)
        let creations = await checkpoints.created
        #expect(await session.applyProposal() == nil)
        #expect(await session.revertAppliedProposal() == nil)
        #expect(await checkpoints.created == creations)
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "let value = 2")
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let runs: URL
        var file: URL { source.appendingPathComponent("Example.swift") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessEditUI-\(UUID())")
            source = root.appendingPathComponent("source")
            runs = root.appendingPathComponent("runs")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("let value = 1".utf8).write(to: file)
        }
        @MainActor func session(editor: any ProjectFileEditing, checkpoints: any GitCheckpointing) -> FileChangeSession {
            FileChangeSession(rootPath: source.path, model: nil, editor: editor,
                gitCheckpointProvider: checkpoints, inferenceProvider: LocalInferenceService(),
                validationProvider: LocalProjectValidationService(), onGenerationEvent: { _ in })
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor Checkpoints: GitCheckpointing {
    var created = 0
    var discarded = 0
    func create(rootPath: String, proposal: FileChangeProposal) -> GitFileCheckpoint? {
        created += 1
        return .init(sourceRootPath: rootPath, repositoryRootPath: rootPath, relativePath: proposal.relativePath,
            originalObjectID: "original", appliedObjectID: "applied")
    }
    func restore(_ checkpoint: GitFileCheckpoint) throws -> FileChangeProposal { throw CancellationError() }
    func discard(_ checkpoint: GitFileCheckpoint) { discarded += 1 }
}
