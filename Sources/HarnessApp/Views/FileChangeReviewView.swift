import HarnessCore
import SwiftUI

struct FileChangeReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: FileChangeSession
    @State private var artifactPlanner: ArtifactPlanSession
    @State private var isConfirmingApply = false
    @State private var isShowingArtifactPlanner = false
    let onApplied: (AppliedFileChange) -> Void
    let onReverted: (AppliedFileChange) -> Void
    let onValidationStarted: @MainActor () -> Void
    let onValidation: @MainActor @Sendable (ProjectValidationReport) -> Void
    let onRepairProgress: (BuildRepairProgress) -> Void
    let onArtifactPlanStarted: (ArtifactCreationPlan) -> Void
    let onArtifactProgress: (ArtifactCreationPlan) -> Void
    let replanModel: ModelSelection?
    let replanInference: any ModelInferenceProvider
    let replanProject: @MainActor () -> HarnessProject?
    let onApplyReplan: (WorkPlanReplanProposal) -> Bool
    let reviewMode: CreationLoopReviewMode
    let onRequestExternalReview: (ProjectValidationReport, BuildFailureAnalysis?) -> Void

    init(
        rootPath: String,
        model: ModelSelection?,
        editor: any ProjectFileEditing,
        gitCheckpointProvider: any GitCheckpointing,
        inferenceProvider: any ModelInferenceProvider,
        validationProvider: any ProjectValidating,
        initialRelativePath: String? = nil,
        initialInstruction: String = "",
        repairPlan: BuildRepairPlan? = nil,
        currentRepairTargetID: String? = nil,
        artifactPlan: ArtifactCreationPlan? = nil,
        onApplied: @escaping (AppliedFileChange) -> Void,
        onReverted: @escaping (AppliedFileChange) -> Void,
        onValidationStarted: @escaping @MainActor () -> Void,
        onValidation: @escaping @MainActor @Sendable (ProjectValidationReport) -> Void,
        onRepairProgress: @escaping (BuildRepairProgress) -> Void,
        onArtifactPlanStarted: @escaping (ArtifactCreationPlan) -> Void,
        onArtifactProgress: @escaping (ArtifactCreationPlan) -> Void,
        replanProject: @escaping @MainActor () -> HarnessProject?,
        onApplyReplan: @escaping (WorkPlanReplanProposal) -> Bool,
        reviewMode: CreationLoopReviewMode,
        onRequestExternalReview: @escaping (
            ProjectValidationReport,
            BuildFailureAnalysis?
        ) -> Void,
        onGenerationEvent: @escaping (FileEditGenerationEvent) -> Void,
        onPlanGenerationEvent: @escaping (ArtifactPlanGenerationEvent) -> Void
    ) {
        _session = State(initialValue: FileChangeSession(
            rootPath: rootPath,
            model: model,
            editor: editor,
            gitCheckpointProvider: gitCheckpointProvider,
            inferenceProvider: inferenceProvider,
            validationProvider: validationProvider,
            initialRelativePath: initialRelativePath,
            initialInstruction: initialInstruction,
            repairPlan: repairPlan,
            currentRepairTargetID: currentRepairTargetID,
            artifactPlan: artifactPlan,
            orchestrator: OrchestratedRunSettings().service,
            onGenerationEvent: onGenerationEvent
        ))
        _artifactPlanner = State(initialValue: ArtifactPlanSession(
            rootPath: rootPath,
            model: model,
            editor: editor,
            inferenceProvider: inferenceProvider,
            onGenerationEvent: onPlanGenerationEvent
        ))
        self.onApplied = onApplied
        self.onReverted = onReverted
        self.onValidationStarted = onValidationStarted
        self.onValidation = onValidation
        self.onRepairProgress = onRepairProgress
        self.onArtifactPlanStarted = onArtifactPlanStarted
        self.onArtifactProgress = onArtifactProgress
        self.replanModel = model
        self.replanInference = inferenceProvider
        self.replanProject = replanProject
        self.onApplyReplan = onApplyReplan
        self.reviewMode = reviewMode
        self.onRequestExternalReview = onRequestExternalReview
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                FileChangeFileList(
                    session: session,
                    onEditingTarget: { isShowingArtifactPlanner = false },
                    onBeginArtifactPlan: { isShowingArtifactPlanner = true }
                )
                .frame(width: 250)
                Divider()
                if isShowingArtifactPlanner {
                    ArtifactPlanComposer(
                        planner: artifactPlanner,
                        existingPaths: session.files.map(\.relativePath),
                        onStart: startArtifactPlan
                    )
                } else {
                    FileChangeWorkspacePanel(
                        session: session,
                        isConfirmingApply: $isConfirmingApply,
                        onReverted: onReverted,
                        onValidationStarted: onValidationStarted,
                        onValidation: onValidation,
                        onRepairProgress: onRepairProgress,
                        onArtifactProgress: onArtifactProgress,
                        replanModel: replanModel,
                        replanInference: replanInference,
                        replanProject: replanProject,
                        onApplyReplan: onApplyReplan,
                        reviewMode: reviewMode,
                        onRequestExternalReview: { report, analysis in
                            dismiss()
                            onRequestExternalReview(report, analysis)
                        }
                    )
                }
            }
        }
        .frame(minWidth: 920, minHeight: 680)
        .task { if session.files.isEmpty { await session.loadFiles() } }
        .onDisappear {
            session.stopAll()
            artifactPlanner.stop()
        }
        .confirmationDialog(
            "この差分を保存しますか？",
            isPresented: $isConfirmingApply,
            titleVisibility: .visible
        ) {
            Button("承認して保存", action: applyProposal)
            Button("キャンセル", role: .cancel) {}
        } message: {
            if let proposal = session.proposal {
                Text(confirmationMessage(for: proposal))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.badge.gearshape")
                .font(.harness(.title2))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("安全なファイル編集")
                    .font(.harness(.headline))
                Text("変更または新規作成の案を、差分確認後に1ファイルだけ保存します。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("完了") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func startArtifactPlan(_ plan: ArtifactCreationPlan) {
        session.startArtifactPlan(plan)
        onArtifactPlanStarted(plan)
        isShowingArtifactPlanner = false
    }

    private func applyProposal() {
        Task {
            guard let applied = await session.applyProposal() else { return }
            onApplied(applied)
            if let progress = session.repairProgress { onRepairProgress(progress) }
            if let plan = session.artifactPlan { onArtifactProgress(plan) }
            session.startPostEditValidation(
                onStart: onValidationStarted,
                onComplete: onValidation
            )
        }
    }

    private func confirmationMessage(for proposal: FileChangeProposal) -> String {
        let action = proposal.operation == .creation ? "新規作成" : "書き換え"
        return "\(proposal.relativePath)だけを\(action)します（+\(proposal.summary.addedLineCount) / −\(proposal.summary.removedLineCount)）。"
    }
}
