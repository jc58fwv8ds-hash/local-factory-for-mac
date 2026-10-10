import Foundation
import HarnessCore
import HarnessKernel
import HarnessKernelContracts
import HarnessKernelPersistence

public enum ValidationRecoveryStatus: String, Sendable {
    case verified, legacyVerified, sourceChanged, evidenceUnavailable, journalUnavailable, incomplete, unresolved

    public var explanation: String {
        switch self {
        case .verified: "保存した検証結果と現在のソースが一致しています。"
        case .legacyVerified: "旧形式の検証報告とソースは一致しています。画像などの追加証拠は保証対象外です。"
        case .sourceChanged: "前回の検証後にソースが変わっています。もう一度検証が必要です。"
        case .evidenceUnavailable: "検証の証拠を照合できませんでした。過去の合格をそのまま使用しません。"
        case .journalUnavailable: "作業履歴を安全に読み取れませんでした。自動再実行はしていません。"
        case .incomplete: "検証の完了記録がありません。自動再実行はしていません。"
        case .unresolved: "中断した操作の結果が未確定です。状況を確認してから再開してください。"
        }
    }
}

/// Read/verify boundary for RecordedProjectValidationService runs, not a generic Kernel resume.
/// Never rewrites history, launches tools that build, or retries an unresolved external operation.
public struct ValidationRecoveryService: Sendable {
    public init() {}

    public func inspect(runDirectory: URL, root: URL) async throws -> ValidationRecoveryStatus {
        try Task.checkCancellation()
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let run = runDirectory.standardizedFileURL
        let eventsURL = run.appendingPathComponent("events")
        let journal: FileKernelJournal
        let events: [KernelEvent]
        var state: KernelState
        do {
            for url in [run, eventsURL] {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { return .journalUnavailable }
            }
            journal = try FileKernelJournal(directory: eventsURL)
            events = try journal.read()
            guard let first = events.first else { return .incomplete }
            state = KernelState(runID: first.runID)
            for event in events { try state.apply(event) }
        } catch { return .journalUnavailable }
        if state.activeAttempt != nil { return .unresolved }
        guard state.phase == .completed else { return .incomplete }
        do {
            guard let plan = state.plan, plan.modelIdentifier == "deterministic-validation-adapter",
                  plan.steps.count == 1, state.evidence.count == plan.requirements.count,
                  plan.requirements.allSatisfy({ [.build, .testExecution, .ui].contains($0.kind) }) else {
                return .evidenceUnavailable
            }
            let references = Set(state.evidence.values.map(\.reportReference))
            guard references.count == 1, let reference = references.first,
                  reference.range(of: #"^validation\.json#sha256=[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
                return .evidenceUnavailable
            }
            let hash = String(reference.suffix(64))
            // Verify historical bytes before comparing their source fingerprint with current files.
            let receipt = try ValidationReceiptStore(runDirectory: run).verified(
                hash: hash, runID: state.runID, root: root, sourceDigest: nil, revision: state.revision
            )
            let needsTests = plan.requirements.contains { $0.kind == .testExecution || $0.kind == .ui }
            guard ValidationResultPolicy.normalize(receipt.report, requireTests: needsTests).succeeded else {
                return .evidenceUnavailable
            }
            let ui = plan.requirements.filter { $0.kind == .ui }
            guard ui.isEmpty ? receipt.uiAcceptance == nil :
                    (ui.count == 1 && receipt.uiAcceptance?.criterion == ui[0].criterion) else {
                return .evidenceUnavailable
            }
            guard try await ValidationSourceIdentity.digest(root: root) == receipt.sourceDigest else { return .sourceChanged }
            try Task.checkCancellation()
            // Do not publish a snapshot if another writer advanced the journal during verification.
            guard try journal.read() == events else { return .journalUnavailable }
            return receipt.schemaVersion == 1 ? .legacyVerified : .verified
        } catch is CancellationError { throw CancellationError() }
        catch { return .evidenceUnavailable }
    }
}
