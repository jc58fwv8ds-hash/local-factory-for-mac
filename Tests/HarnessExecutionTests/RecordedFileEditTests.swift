import Foundation
import HarnessCore
import HarnessKernel
import HarnessKernelContracts
import HarnessKernelPersistence
@testable import HarnessExecution
import Testing

struct RecordedFileEditTests {
    @Test(arguments: [false, true])
    func reviewIsReadOnlyAndApprovedApplyAndUndoAreRecorded(creation: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let proposal = try await fixture.proposal(editor: service, creation: creation)
        #expect(!FileManager.default.fileExists(atPath: fixture.runs.path))
        try await service.apply(rootPath: fixture.source.path, proposal: proposal)
        #expect(try await service.load(rootPath: fixture.source.path, relativePath: proposal.relativePath).content == proposal.proposedContent)
        let run = try #require(await service.lastRunDirectory)
        let state = try await fixture.state(run: run)
        #expect(state.phase == .paused && state.activeAttempt == nil && state.nextStep == nil)
        #expect(!state.canComplete && state.evidence.isEmpty)
        let checkpoint = try Data(contentsOf: run.appendingPathComponent("checkpoint.json"))
        let object = try #require(JSONSerialization.jsonObject(with: checkpoint) as? [String: Any])
        #expect(object["originalContent"] as? String == proposal.originalContent)
        #expect(object["proposedContent"] as? String == proposal.proposedContent)
        let permissions = try FileManager.default.attributesOfItem(atPath: run.appendingPathComponent("checkpoint.json").path)
        #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // A new adapter instance uses the persisted run; undo is another explicit operation.
        let reopened = fixture.service()
        try await reopened.revert(rootPath: fixture.source.path, proposal: proposal)
        let undoRun = try #require(await reopened.lastRunDirectory)
        #expect(undoRun != run)
        #expect(try await fixture.state(run: undoRun).activeAttempt == nil)
        if creation {
            #expect(!FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent(proposal.relativePath).path))
        } else {
            #expect(try String(contentsOf: fixture.file, encoding: .utf8) == proposal.originalContent)
        }
    }

    @Test(arguments: ["throwAfterWrite", "noWrite", "brokenJournal"])
    func uncertainOutcomesKeepBackupAndBlockANewSession(mode: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let proposal = try await fixture.proposal(editor: ProjectFileEditor())
        let service = fixture.service(provider: FaultingEditor(mode: mode, runs: fixture.runs))
        await #expect(throws: RecordedFileEditError.needsInspection) {
            try await service.apply(rootPath: fixture.source.path, proposal: proposal)
        }
        let run = try #require(await service.lastRunDirectory)
        let backup = try Data(contentsOf: run.appendingPathComponent("checkpoint.json"))
        let expected = mode == "noWrite" ? proposal.originalContent : proposal.proposedContent
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == expected)
        let reopened = fixture.service()
        await #expect(throws: RecordedFileEditError.needsInspection) {
            try await reopened.apply(rootPath: fixture.source.path, proposal: proposal)
        }
        #expect(await reopened.lastRunDirectory == nil)
        #expect(try Data(contentsOf: run.appendingPathComponent("checkpoint.json")) == backup)
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == expected)
        if mode != "brokenJournal" {
            let state = try await fixture.state(run: run)
            #expect(state.phase == .paused && state.activeAttempt != nil)
        }
    }

    @Test func staleProposalAndUnavailableRecordingNeverWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let proposal = try await fixture.proposal(editor: ProjectFileEditor())
        try Data("let external = 9".utf8).write(to: fixture.file)
        let service = fixture.service()
        await #expect(throws: ProjectFileEditError.changedSinceReview) {
            try await service.apply(rootPath: fixture.source.path, proposal: proposal)
        }
        #expect(await service.lastRunDirectory == nil)
        let blockedDirectory = fixture.root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: blockedDirectory)
        let unavailable = RecordedProjectFileEditor(directory: blockedDirectory)
        await #expect(throws: (any Error).self) {
            try await unavailable.apply(rootPath: fixture.source.path, proposal: proposal)
        }
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "let external = 9")
    }

    @Test func competingLeaseAndCorruptIndexNeverStartAnEdit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.runs, withIntermediateDirectories: true)
        let proposal = try await fixture.proposal(editor: ProjectFileEditor())
        let key = ValidationSourceIdentity.hash(Data(fixture.source.path.utf8))
        do {
            let lease = try LocalExecutionLease(file: fixture.runs.appendingPathComponent("execution-\(key).lock"))
            defer { withExtendedLifetime(lease) {} }
            await #expect(throws: RecordedFileEditError.busy) {
                try await fixture.service().apply(rootPath: fixture.source.path, proposal: proposal)
            }
        }
        try Data("broken".utf8).write(to: fixture.runs.appendingPathComponent("latest-\(key).run"))
        await #expect(throws: RecordedFileEditError.needsInspection) {
            try await fixture.service().apply(rootPath: fixture.source.path, proposal: proposal)
        }
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == proposal.originalContent)
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let runs: URL
        var file: URL { source.appendingPathComponent("Example.swift") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessRecordedEdit-\(UUID())").resolvingSymlinksInPath()
            source = root.appendingPathComponent("source")
            runs = root.appendingPathComponent("runs")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("let value = 1".utf8).write(to: file)
        }

        func service(provider: any ProjectFileEditing = ProjectFileEditor()) -> RecordedProjectFileEditor {
            RecordedProjectFileEditor(provider: provider, directory: runs)
        }

        func proposal(editor: any ProjectFileEditing, creation: Bool = false) async throws -> FileChangeProposal {
            if creation {
                return try await editor.makeCreationProposal(rootPath: source.path, relativePath: "New.swift", proposedContent: "let value = 2")
            }
            return try await editor.makeProposal(document: editor.load(rootPath: source.path, relativePath: "Example.swift"), proposedContent: "let value = 2")
        }

        func state(run: URL) async throws -> KernelState {
            let id = try #require(UUID(uuidString: run.lastPathComponent))
            return try await KernelEngine(runID: id, journal: FileKernelJournal(directory: run.appendingPathComponent("events"))).snapshot()
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private struct FaultingEditor: ProjectFileEditing {
    let mode: String
    let runs: URL
    private let real = ProjectFileEditor()
    func editableFiles(rootPath: String) async throws -> [EditableSourceFile] { try await real.editableFiles(rootPath: rootPath) }
    func load(rootPath: String, relativePath: String) async throws -> EditableSourceDocument {
        try await real.load(rootPath: rootPath, relativePath: relativePath)
    }
    func makeProposal(document: EditableSourceDocument, proposedContent: String) async throws -> FileChangeProposal {
        try await real.makeProposal(document: document, proposedContent: proposedContent)
    }
    func makeCreationProposal(rootPath: String, relativePath: String, proposedContent: String) async throws -> FileChangeProposal {
        try await real.makeCreationProposal(rootPath: rootPath, relativePath: relativePath, proposedContent: proposedContent)
    }
    func validateCreationPath(rootPath: String, relativePath: String) async throws {
        try await real.validateCreationPath(rootPath: rootPath, relativePath: relativePath)
    }
    func apply(rootPath: String, proposal: FileChangeProposal) async throws {
        if mode == "noWrite" { return }
        try await real.apply(rootPath: rootPath, proposal: proposal)
        if mode == "brokenJournal" {
            let id = try #require(try RootRunIndex(directory: runs).load(root: URL(fileURLWithPath: rootPath)))
            try Data("broken".utf8).write(to: runs.appendingPathComponent("\(id)/events/00000003.json"))
        } else { throw CancellationError() }
    }
    func revert(rootPath: String, proposal: FileChangeProposal) async throws { try await real.revert(rootPath: rootPath, proposal: proposal) }
}
