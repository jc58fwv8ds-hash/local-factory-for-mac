import Foundation
import HarnessCore
import HarnessKernel
import HarnessKernelContracts
import HarnessKernelPersistence

/// Records explicitly requested single-file writes. Never grants approval or runs a repair loop.
public actor RecordedProjectFileEditor: ProjectFileEditing {
    private let provider: any ProjectFileEditing
    private let directory: URL
    private var activeRoots = Set<String>()
    public private(set) var lastRunDirectory: URL?

    public init(provider: any ProjectFileEditing = ProjectFileEditor(), directory: URL? = nil) {
        self.provider = provider
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harness/KernelEdits", isDirectory: true)
    }

    public func editableFiles(rootPath: String) async throws -> [EditableSourceFile] {
        try await provider.editableFiles(rootPath: rootPath)
    }

    public func load(rootPath: String, relativePath: String) async throws -> EditableSourceDocument {
        try await provider.load(rootPath: rootPath, relativePath: relativePath)
    }

    public func makeProposal(document: EditableSourceDocument, proposedContent: String) async throws -> FileChangeProposal {
        try await provider.makeProposal(document: document, proposedContent: proposedContent)
    }

    public func makeCreationProposal(rootPath: String, relativePath: String, proposedContent: String) async throws -> FileChangeProposal {
        try await provider.makeCreationProposal(rootPath: rootPath, relativePath: relativePath, proposedContent: proposedContent)
    }

    public func validateCreationPath(rootPath: String, relativePath: String) async throws {
        try await provider.validateCreationPath(rootPath: rootPath, relativePath: relativePath)
    }

    public func apply(rootPath: String, proposal: FileChangeProposal) async throws {
        try await perform(rootPath: rootPath, proposal: proposal, reverting: false)
    }

    public func revert(rootPath: String, proposal: FileChangeProposal) async throws {
        try await perform(rootPath: rootPath, proposal: proposal, reverting: true)
    }

    private func perform(rootPath: String, proposal: FileChangeProposal, reverting: Bool) async throws {
        try Task.checkCancellation()
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        guard activeRoots.insert(root.path).inserted else { throw RecordedFileEditError.busy }
        defer { activeRoots.remove(root.path) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lease: LocalExecutionLease
        do {
            let key = ValidationSourceIdentity.hash(Data(root.path.utf8))
            lease = try LocalExecutionLease(file: directory.appendingPathComponent("execution-\(key).lock"))
        } catch LocalExecutionLeaseError.inUse { throw RecordedFileEditError.busy }
        defer { withExtendedLifetime(lease) {} }
        let index = RootRunIndex(directory: directory)
        try await requireResolvedPreviousRun(index: index, root: root)
        // Reject stale proposals before creating an operation that could require reconciliation.
        if proposal.operation == .creation && !reverting {
            try await provider.validateCreationPath(rootPath: root.path, relativePath: proposal.relativePath)
        } else {
            let before = try await provider.load(rootPath: root.path, relativePath: proposal.relativePath)
            guard before.content == (reverting ? proposal.proposedContent : proposal.originalContent) else {
                throw ProjectFileEditError.changedSinceReview
            }
        }
        try Task.checkCancellation()
        let id = UUID()
        let run = directory.appendingPathComponent(id.uuidString)
        let engine = try KernelEngine(runID: id, journal: FileKernelJournal(directory: run.appendingPathComponent("events")))
        let checkpoint = try FileEditCheckpoint.save(proposal: proposal, reverting: reverting, root: root, directory: run)
        let step = KernelStep(instruction: reverting ? "承認済みの1ファイル変更を元に戻す" : "確認された変更案を1ファイルへ保存する")
        try await engine.record(.planned(KernelPlan(userRequest: step.instruction,
            modelIdentifier: "approved-file-edit-adapter", steps: [step],
            requirements: [.init(criterion: "変更後の制作物を別途検証する。保存だけでは完成ではない", kind: .acceptance)])))
        try await engine.record(.decisionRecorded("対象: \(proposal.relativePath)。編集前後の控え: \(checkpoint)"))
        try index.save(runID: id, root: root)
        lastRunDirectory = run
        let attempt = UUID()
        try await engine.record(.stepStarted(stepID: step.id, attemptID: attempt))
        do {
            try Task.checkCancellation()
            if reverting { try await provider.revert(rootPath: root.path, proposal: proposal) }
            else { try await provider.apply(rootPath: root.path, proposal: proposal) }
            try Task.checkCancellation()
            if reverting && proposal.operation == .creation {
                // This checks absence using the same path policy as creation, not an unchecked URL.
                try await provider.validateCreationPath(rootPath: root.path, relativePath: proposal.relativePath)
            } else {
                let after = try await provider.load(rootPath: root.path, relativePath: proposal.relativePath)
                guard after.content == (reverting ? proposal.originalContent : proposal.proposedContent) else {
                    throw RecordedFileEditError.needsInspection
                }
            }
            try await engine.record(.stepFinished(attemptID: attempt, succeeded: true))
            try await engine.record(.paused(reason: "ファイルの保存結果は確認できました。制作物のビルド・テスト・品質評価は別途必要です。"))
        } catch {
            // Even a thrown adapter error can follow a write. Do not discard backups or retry it.
            let state = await engine.snapshot()
            if state.phase == .ready || state.phase == .executing {
                _ = try? await engine.record(.paused(reason: "編集結果の確認が必要です。控えを保持し、自動再適用を停止しました。"))
            }
            throw RecordedFileEditError.needsInspection
        }
    }

    private func requireResolvedPreviousRun(index: RootRunIndex, root: URL) async throws {
        do {
            guard let id = try index.load(root: root) else { return }
            let events = directory.appendingPathComponent(id.uuidString).appendingPathComponent("events")
            guard FileManager.default.fileExists(atPath: events.path) else { throw KernelError.corruptJournal }
            let engine = try KernelEngine(runID: id, journal: FileKernelJournal(directory: events))
            let state = await engine.snapshot()
            guard state.phase == .paused, state.activeAttempt == nil, state.nextStep == nil,
                  state.modelIdentifier == "approved-file-edit-adapter" else {
                throw RecordedFileEditError.needsInspection
            }
        } catch { throw RecordedFileEditError.needsInspection }
    }
}

public enum RecordedFileEditError: LocalizedError, Equatable, Sendable {
    case busy, needsInspection

    public var errorDescription: String? {
        switch self {
        case .busy: "このプロジェクトで別の編集が進んでいます。終わってから操作してください。"
        case .needsInspection: "ファイルが変更されている可能性があるため、再適用を止めました。復元用の控えは保持しています。現在の内容と編集記録を確認してください。"
        }
    }
}
