import HarnessCore
import SwiftUI
import UniformTypeIdentifiers

extension View {
    func activityInspectorPresentation(
        store: WorkspaceStore,
        isSelectingSourceFolder: Binding<Bool>,
        sourceSelectionError: Binding<String?>,
        fileEditContext: Binding<FileEditContext?>,
        validationContext: Binding<ValidationContext?>,
        restoreContext: Binding<RestoreContext?>,
        externalReviewContext: Binding<ExternalReviewContext?>,
        isShowingSimulator: Binding<Bool>,
        physicalDeviceContext: Binding<PhysicalDeviceContext?>,
        sourceDisconnectProjectID: Binding<UUID?>,
        onSourceSelection: @escaping (Result<[URL], Error>) -> Void,
        onBeginRepair: @escaping (
            BuildRepairPlan,
            BuildRepairTarget,
            ValidationContext
        ) -> Void,
        onBeginExternalReview: @escaping (
            UUID,
            String,
            ProjectValidationReport,
            BuildFailureAnalysis?
        ) -> Void
    ) -> some View {
        modifier(
            ActivityInspectorPresentation(
                store: store,
                isSelectingSourceFolder: isSelectingSourceFolder,
                sourceSelectionError: sourceSelectionError,
                fileEditContext: fileEditContext,
                validationContext: validationContext,
                restoreContext: restoreContext,
                externalReviewContext: externalReviewContext,
                isShowingSimulator: isShowingSimulator,
                physicalDeviceContext: physicalDeviceContext,
                sourceDisconnectProjectID: sourceDisconnectProjectID,
                onSourceSelection: onSourceSelection,
                onBeginRepair: onBeginRepair,
                onBeginExternalReview: onBeginExternalReview
            )
        )
    }
}

private struct ActivityInspectorPresentation: ViewModifier {
    @Bindable var store: WorkspaceStore
    @Binding var isSelectingSourceFolder: Bool
    @Binding var sourceSelectionError: String?
    @Binding var fileEditContext: FileEditContext?
    @Binding var validationContext: ValidationContext?
    @Binding var restoreContext: RestoreContext?
    @Binding var externalReviewContext: ExternalReviewContext?
    @Binding var isShowingSimulator: Bool
    @Binding var physicalDeviceContext: PhysicalDeviceContext?
    @Binding var sourceDisconnectProjectID: UUID?
    let onSourceSelection: (Result<[URL], Error>) -> Void
    let onBeginRepair: (
        BuildRepairPlan,
        BuildRepairTarget,
        ValidationContext
    ) -> Void
    let onBeginExternalReview: (
        UUID,
        String,
        ProjectValidationReport,
        BuildFailureAnalysis?
    ) -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isSelectingSourceFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: onSourceSelection
            )
            .alert(
                "フォルダを接続できませんでした",
                isPresented: sourceErrorBinding
            ) {
                Button("OK") { sourceSelectionError = nil }
            } message: {
                Text(sourceSelectionError ?? "不明なエラー")
            }
            .sheet(item: $fileEditContext, content: fileChangeReview)
            .sheet(item: $validationContext, content: projectValidation)
            .sheet(item: $restoreContext, content: restorePoints)
            .sheet(item: $externalReviewContext, content: externalReview)
            .sheet(isPresented: $isShowingSimulator) {
                SimulatorView(provider: store.simulatorProvider)
            }
            .sheet(item: $physicalDeviceContext) { context in
                PhysicalDeviceView(
                    rootPath: context.rootPath,
                    provider: store.physicalDeviceProvider,
                    opener: store.xcodeProjectOpener
                )
            }
            .confirmationDialog(
                "ソースフォルダの接続を解除しますか？",
                isPresented: disconnectConfirmationBinding,
                titleVisibility: .visible
            ) {
                Button("接続を解除", action: disconnectSource)
                Button("キャンセル", role: .cancel) {
                    sourceDisconnectProjectID = nil
                }
            } message: {
                Text("Local Factory内の参照だけを解除します。元のフォルダやファイルは削除しません。")
            }
    }

    private func fileChangeReview(_ context: FileEditContext) -> some View {
        FileChangeReviewView(
            rootPath: context.rootPath,
            model: context.model,
            editor: store.fileEditor,
            gitCheckpointProvider: store.gitCheckpointProvider,
            inferenceProvider: store.inferenceProvider,
            validationProvider: store.validationProvider,
            initialRelativePath: context.initialRelativePath,
            initialInstruction: context.initialInstruction,
            repairPlan: context.repairPlan,
            currentRepairTargetID: context.currentRepairTargetID,
            artifactPlan: context.artifactPlan,
            onApplied: {
                store.recordAppliedFileChange($0, projectID: context.projectID)
            },
            onReverted: {
                store.recordRevertedFileChange($0, projectID: context.projectID)
            },
            onValidationStarted: {
                store.recordValidationStarted(projectID: context.projectID)
            },
            onValidation: {
                store.recordValidation($0, projectID: context.projectID)
            },
            onRepairProgress: {
                store.recordRepairProgress($0, projectID: context.projectID)
            },
            onArtifactPlanStarted: {
                store.recordArtifactPlanStarted($0, projectID: context.projectID)
            },
            onArtifactProgress: {
                store.recordArtifactPlanProgress($0, projectID: context.projectID)
            },
            replanProject: { project(for: context.projectID) },
            onApplyReplan: {
                store.applyWorkPlanReplan($0, projectID: context.projectID)
            },
            reviewMode: reviewMode(for: context.projectID),
            onRequestExternalReview: { report, analysis in
                onBeginExternalReview(
                    context.projectID,
                    context.rootPath,
                    report,
                    analysis
                )
            },
            onGenerationEvent: {
                store.recordFileEditGeneration(
                    $0,
                    projectID: context.projectID
                )
            },
            onPlanGenerationEvent: {
                store.recordArtifactPlanGeneration(
                    $0,
                    projectID: context.projectID
                )
            }
        )
    }

    private func projectValidation(_ context: ValidationContext) -> some View {
        ProjectValidationView(
            rootPath: context.rootPath,
            provider: store.validationProvider,
            model: project(for: context.projectID)?.selectedModel,
            inference: store.inferenceProvider,
            project: { project(for: context.projectID) },
            onApplyReplan: {
                store.applyWorkPlanReplan($0, projectID: context.projectID)
            },
            startsAutomatically: context.startsAutomatically,
            onStart: {
                store.recordValidationStarted(projectID: context.projectID)
            },
            onComplete: {
                store.recordValidation($0, projectID: context.projectID)
            },
            onRequestRepair: { plan, target in
                onBeginRepair(plan, target, context)
            },
            reviewMode: reviewMode(for: context.projectID),
            onRequestExternalReview: { report, analysis in
                onBeginExternalReview(
                    context.projectID,
                    context.rootPath,
                    report,
                    analysis
                )
            }
        )
    }

    private func externalReview(_ context: ExternalReviewContext) -> some View {
        let project = store.library.records.first {
            $0.id == context.projectID
        }?.project ?? store.project
        return ExternalReviewView(
            project: project,
            rootPath: context.rootPath,
            report: context.report,
            analysis: context.analysis,
            sourceProvider: store.sourceContextProvider,
            handoff: store.externalReviewHandoff,
            onImport: {
                store.recordExternalReview($0, projectID: context.projectID)
            }
        )
    }

    private func reviewMode(for projectID: UUID) -> CreationLoopReviewMode {
        project(for: projectID)?.creationLoop.reviewMode ?? .localOnly
    }

    private func project(for projectID: UUID) -> HarnessProject? {
        store.library.records.first { $0.id == projectID }?.project
    }

    private func restorePoints(_ context: RestoreContext) -> some View {
        GitRestorePointsView(
            checkpoints: context.checkpoints,
            provider: store.gitCheckpointProvider,
            onRestored: {
                store.recordRestoredCheckpoint($0, projectID: context.projectID)
            }
        )
    }

    private var sourceErrorBinding: Binding<Bool> {
        Binding(
            get: { sourceSelectionError != nil },
            set: { if !$0 { sourceSelectionError = nil } }
        )
    }

    private var disconnectConfirmationBinding: Binding<Bool> {
        Binding(
            get: { sourceDisconnectProjectID != nil },
            set: { if !$0 { sourceDisconnectProjectID = nil } }
        )
    }

    private func disconnectSource() {
        if let projectID = sourceDisconnectProjectID {
            store.disconnectSourceFolder(from: projectID)
        }
        sourceDisconnectProjectID = nil
    }
}
