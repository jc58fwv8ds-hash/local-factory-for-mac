import HarnessCore
import SwiftUI

struct FileChangeWorkspacePanel: View {
    @Bindable var session: FileChangeSession
    @Binding var isConfirmingApply: Bool
    let onReverted: (AppliedFileChange) -> Void
    let onValidationStarted: @MainActor () -> Void
    let onValidation: @MainActor @Sendable (ProjectValidationReport) -> Void
    let onRepairProgress: (BuildRepairProgress) -> Void
    let onArtifactProgress: (ArtifactCreationPlan) -> Void
    let replanModel: ModelSelection?
    let replanInference: any ModelInferenceProvider
    let replanProject: @MainActor () -> HarnessProject?
    let onApplyReplan: (WorkPlanReplanProposal) -> Bool
    let reviewMode: CreationLoopReviewMode
    let onRequestExternalReview: (ProjectValidationReport, BuildFailureAnalysis?) -> Void

    var body: some View {
        if session.document != nil || session.isCreatingNewFile {
            VStack(alignment: .leading, spacing: 12) {
                fileHeader
                safetyNotice
                FileRepairPlanPanel(session: session, onProgress: onRepairProgress)
                ArtifactCreationPlanPanel(session: session, onProgress: onArtifactProgress)
                aiComposer
                modePicker
                editorOrDiff
                FileChangeValidationPanel(
                    validation: session.validation,
                    isEnabled: Binding(
                        get: { session.shouldValidateAfterApply },
                        set: { session.shouldValidateAfterApply = $0 }
                    ),
                    isApplied: session.isApplied,
                    requiresFinalPlanValidation: session.artifactPlan != nil,
                    onRetry: retryValidation,
                    replanModel: replanModel,
                    replanInference: replanInference,
                    replanProject: replanProject,
                    onApplyReplan: onApplyReplan,
                    reviewMode: reviewMode,
                    onRequestExternalReview: onRequestExternalReview
                )
                if let error = session.errorMessage { errorBanner(error) }
                if let run = session.orchestratedOutcome { orchestratedSummary(run) }
                footer
            }
            .padding(16)
        } else {
            ContentUnavailableView(
                "ファイルを選択",
                systemImage: "doc.text.magnifyingglass",
                description: Text("左側から編集対象を選ぶか、成果物計画を作成してください。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func orchestratedSummary(_ run: OrchestratedEditOutcome) -> some View {
        Label("オーケストレーター実行(実験): テスト通過(\(run.testsPassedResult))。要件検証は未完了です。承認するまでプロジェクトは変わりません。",
              systemImage: "checklist")
            .font(.harness(.caption))
            .foregroundStyle(.secondary)
        if !session.relatedProposals.isEmpty { relatedChanges }
    }

    /// The other files of the same change: reviewed here and applied or reverted together with the file above.
    private var relatedChanges: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ほかに変更されるファイル(\(session.relatedProposals.count)件、承認するとまとめて適用・取り消しされます)")
                .font(.harness(.caption, weight: .semibold))
            ForEach(session.relatedProposals, id: \.relativePath) { related in
                DisclosureGroup {
                    FileDiffPreview(proposal: related).frame(minHeight: 120, maxHeight: 260)
                } label: {
                    Label(related.relativePath + (related.operation == .creation ? "(新規)" : ""),
                          systemImage: related.operation == .creation ? "doc.badge.plus" : "doc.text")
                        .font(.harness(.caption).monospaced())
                }
            }
        }
    }

    private var fileHeader: some View {
        HStack {
            if session.isCreatingNewFile {
                TextField(
                    "例：Sources/NewFeature.swift",
                    text: Binding(
                        get: { session.newFileRelativePath },
                        set: { session.updateNewFileRelativePath($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.harness(.subheadline, weight: .semibold).monospaced())
                .disabled(session.isBusy || session.isApplied || session.artifactPlan != nil)
            } else if let document = session.document {
                Text(document.relativePath)
                    .font(.harness(.subheadline, weight: .semibold).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if session.isApplied {
                Label("保存済み", systemImage: "checkmark.seal.fill")
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(.green)
            }
        }
    }

    private var safetyNotice: some View {
        Label(
            session.isCreatingNewFile
                ? "既存フォルダ内へ1ファイルだけ作成します。同名ファイルがあれば上書きせず停止します。"
                : "削除は行いません。保存直前に元ファイルの競合を再確認します。",
            systemImage: "lock.shield"
        )
        .font(.harness(.caption))
        .foregroundStyle(.secondary)
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var aiComposer: some View {
        HStack(spacing: 9) {
            TextField(
                "例：エラー処理を追加して",
                text: $session.aiInstruction,
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .disabled(session.isBusy || session.isApplied)
            Button {
                session.isGenerating ? session.stopAI() : session.askAI()
            } label: {
                Label(
                    session.isGenerating ? "停止" : "AIで変更案を作成",
                    systemImage: session.isGenerating ? "stop.fill" : "sparkles"
                )
            }
            .buttonStyle(.bordered)
            .disabled(!session.isGenerating && !session.canAskAI)
            .help(session.model == nil ? "先にAIモデルを選択してください" : "選択中のローカルAIを使用")
        }
    }

    private var modePicker: some View {
        Picker("表示", selection: $session.presentationMode) {
            ForEach(FileChangePresentationMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(session.proposal == nil)
    }

    @ViewBuilder
    private var editorOrDiff: some View {
        if session.presentationMode == .diff, let proposal = session.proposal {
            FileDiffPreview(proposal: proposal)
        } else {
            TextEditor(
                text: Binding(
                    get: { session.proposedContent },
                    set: { session.updateProposedContent($0) }
                )
            )
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(7)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            .disabled(session.isBusy || session.isApplied)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.harness(.caption))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            if session.isApplied {
                Button(session.validation.report?.succeeded == false
                    ? "検証失敗を元に戻す"
                    : "元に戻す") {
                    Task {
                        if let reverted = await session.revertAppliedProposal() {
                            onReverted(reverted)
                            if let progress = session.repairProgress {
                                onRepairProgress(progress)
                            }
                            if let plan = session.artifactPlan { onArtifactProgress(plan) }
                        }
                    }
                }
                .disabled(session.isBusy)
            } else {
                Button("編集案をリセット") { session.resetProposal() }
                    .disabled(session.isBusy || !session.canReview)
            }
            Spacer()
            if session.isApplying { ProgressView().controlSize(.small) }
            Button("差分を確認") { Task { await session.prepareReview() } }
                .buttonStyle(.bordered)
                .disabled(!session.canReview)
            Button(session.isCreatingNewFile ? "このファイルを作成" : "この変更を適用") {
                isConfirmingApply = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.proposal == nil || session.isBusy || session.isApplied)
        }
    }

    private func retryValidation() {
        session.startPostEditValidation(
            automatically: false,
            onStart: onValidationStarted,
            onComplete: onValidation
        )
    }
}
