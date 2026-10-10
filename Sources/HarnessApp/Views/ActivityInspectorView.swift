import HarnessCore
import SwiftUI
import UniformTypeIdentifiers

struct ActivityInspectorView: View {
    @Bindable var store: WorkspaceStore
    @State private var isSelectingSourceFolder = false
    @State private var sourceSelectionError: String?
    @State private var fileEditContext: FileEditContext?
    @State private var validationContext: ValidationContext?
    @State private var restoreContext: RestoreContext?
    @State private var externalReviewContext: ExternalReviewContext?
    @State private var isShowingSimulator = false
    @State private var physicalDeviceContext: PhysicalDeviceContext?
    @State private var sourceDisconnectProjectID: UUID?
    @State private var isShowingAppStarter = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                CreationLoopCard(store: store)
                RunCoordinatorCard(
                    store: store,
                    onBegin: { beginRunItem(resumesCurrent: false) },
                    onContinue: continueRunItem,
                    onValidate: validateRun
                )
                modelCard
                RemoteControlCard(
                    remote: store.remoteControl,
                    selectedProjectName: store.library.selectedRecord?.project.name
                )
                if let record = store.library.selectedRecord {
                    SourceInspectorCard(
                        record: record,
                        isInspecting: store.isInspectingSource(for: record.id),
                        sourceChange: store.sourceChangeSummary(for: record.id),
                        onConnect: { isSelectingSourceFolder = true },
                        onCreateIPhoneApp: { isShowingAppStarter = true },
                        onInspect: { store.inspectSource(for: record.id) },
                        onEdit: { beginFileEdit(record) },
                        onValidate: { beginValidation(record) },
                        onResumeValidation: {
                            beginValidation(record, startsAutomatically: true)
                        },
                        onResumeFileEdit: {
                            store.discardOperationCheckpoint(projectID: record.id)
                            beginFileEdit(record)
                        },
                        onDiscardOperation: {
                            store.discardOperationCheckpoint(projectID: record.id)
                        },
                        onResumeArtifactPlan: { resumeArtifactPlan(record) },
                        onDiscardArtifactPlan: {
                            store.discardArtifactCreationPlan(projectID: record.id)
                        },
                        onResumeRepair: { beginValidation(record, startsAutomatically: true) },
                        onDiscardRepair: {
                            store.discardRepairResumeState(projectID: record.id)
                        },
                        onSimulator: { isShowingSimulator = true },
                        onPhysicalDevice: {
                            guard let rootPath = record.sourceLocation else { return }
                            physicalDeviceContext = PhysicalDeviceContext(rootPath: rootPath)
                        },
                        onShowCheckpoints: { beginRestore(record) },
                        onDisconnect: { sourceDisconnectProjectID = record.id }
                    )
                }
                safetyCard
                RecentProjectActivitySection(
                    events: store.project.activity,
                    showsDetails: $store.showsDetails
                )
            }
            .padding(16)
        }
        .background(.ultraThinMaterial)
        .activityInspectorPresentation(
            store: store,
            isSelectingSourceFolder: $isSelectingSourceFolder,
            sourceSelectionError: $sourceSelectionError,
            fileEditContext: $fileEditContext,
            validationContext: $validationContext,
            restoreContext: $restoreContext,
            externalReviewContext: $externalReviewContext,
            isShowingSimulator: $isShowingSimulator,
            physicalDeviceContext: $physicalDeviceContext,
            sourceDisconnectProjectID: $sourceDisconnectProjectID,
            onSourceSelection: handleSourceSelection,
            onBeginRepair: beginRepair,
            onBeginExternalReview: beginExternalReview
        )
        .sheet(isPresented: $isShowingAppStarter) {
            if let record = store.library.selectedRecord {
                ExistingProjectAppStarterView(projectName: record.project.name) {
                    store.createManagedIPhoneAppSource(
                        for: record.id, productName: $0, organizationIdentifier: $1
                    )
                }
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("現在", systemImage: "bolt.fill")
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(.orange)
                    .frame(width: 8, height: 8)
            }

            Text(store.project.currentActivity)
                .font(.harness(.headline))

            ProgressView(value: store.project.progress)
                .tint(Color.accentColor)

            HStack {
                Text(store.project.stage.rawValue)
                Spacer()
                Text("\(Int(store.project.progress * 100))%")
                    .monospacedDigit()
            }
            .font(.harness(.caption))
            .foregroundStyle(.secondary)
        }
        .inspectorCard()
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("AIモデル", systemImage: "brain.head.profile")
                    .font(.harness(.subheadline, weight: .semibold))
                Spacer()
                Text(store.project.selectedModel == nil ? "未接続" : "接続済み")
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(store.project.selectedModel == nil ? .orange : .green)
            }

            if let model = store.project.selectedModel {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayName)
                        .font(.harness(.subheadline, weight: .medium))
                    Text(model.runtime.rawValue)
                        .font(.harness(.caption))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("モデルを選んでインストールすると、指示の理解と制作ループを開始できます。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let checkpoint = store.modelManager.acquisitionCheckpoint {
                Label(
                    store.modelManager.isInstalling ? "\(checkpoint.request.displayName)を取得中です" : "\(checkpoint.request.displayName)の取得を再開できます",
                    systemImage: "arrow.down.circle"
                )
                .font(.harness(.caption, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }

            Button(store.project.selectedModel == nil ? "モデルを追加" : "モデルを管理") {
                store.isShowingModelManager = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .inspectorCard()
    }

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("人が主導権を持つ", systemImage: "hand.raised.fill")
                .font(.harness(.subheadline, weight: .semibold))
            SafetyRow(title: "読み取り・診断", isAutomatic: true)
            SafetyRow(title: "ファイル変更", isAutomatic: false)
            SafetyRow(title: "削除・署名・公開", isAutomatic: false)
        }
        .inspectorCard()
    }

    private func handleSourceSelection(_ result: Result<[URL], Error>) {
        do {
            guard let record = store.library.selectedRecord,
                  let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            store.connectSourceFolder(url, to: record.id)
        } catch {
            sourceSelectionError = error.localizedDescription
        }
    }

    private func beginFileEdit(
        _ record: ProjectRecord,
        initialInstruction: String = ""
    ) {
        guard let rootPath = record.sourceLocation else { return }
        fileEditContext = FileEditContext(
            projectID: record.id,
            rootPath: rootPath,
            model: record.project.selectedModel,
            initialRelativePath: nil,
            initialInstruction: initialInstruction,
            repairPlan: nil,
            currentRepairTargetID: nil,
            artifactPlan: nil
        )
    }

    private func beginRunItem(resumesCurrent: Bool) {
        guard let record = store.library.selectedRecord else { return }
        let selection = resumesCurrent
            ? store.resumeCurrentRunItem()
            : store.beginNextRunItem()
        guard let selection else { return }
        beginFileEdit(record, initialInstruction: selection.instruction)
    }

    private func continueRunItem() {
        guard let record = store.library.selectedRecord else { return }
        if (record.project.runCoordinator.phase == .awaitingRepair
            || record.project.runCoordinator.phase == .blocked),
           record.project.repairResumeState != nil {
            _ = store.resumeCurrentRunItem()
            beginValidation(record, startsAutomatically: true)
            return
        }
        beginRunItem(resumesCurrent: true)
    }

    private func validateRun() {
        guard let record = store.library.selectedRecord else { return }
        beginValidation(record, startsAutomatically: true)
    }

    private func beginValidation(
        _ record: ProjectRecord,
        startsAutomatically: Bool = false
    ) {
        guard let rootPath = record.sourceLocation else { return }
        validationContext = ValidationContext(
            projectID: record.id,
            rootPath: rootPath,
            model: record.project.selectedModel,
            startsAutomatically: startsAutomatically
        )
    }

    private func resumeArtifactPlan(_ record: ProjectRecord) {
        guard let plan = record.project.artifactCreationPlan else { return }
        if plan.isFullyApplied {
            beginValidation(record, startsAutomatically: true)
            return
        }
        guard let rootPath = record.sourceLocation else { return }
        fileEditContext = FileEditContext(
            projectID: record.id,
            rootPath: rootPath,
            model: record.project.selectedModel,
            initialRelativePath: nil,
            initialInstruction: "",
            repairPlan: nil,
            currentRepairTargetID: nil,
            artifactPlan: plan
        )
    }

    private func beginRepair(
        _ plan: BuildRepairPlan,
        target: BuildRepairTarget,
        from context: ValidationContext
    ) {
        store.recordRepairPlan(
            plan,
            selectedTargetID: target.id,
            projectID: context.projectID
        )
        let repairContext = FileEditContext(
            projectID: context.projectID,
            rootPath: context.rootPath,
            model: context.model,
            initialRelativePath: target.relativePath,
            initialInstruction: target.instruction,
            repairPlan: plan,
            currentRepairTargetID: target.id,
            artifactPlan: nil
        )
        validationContext = nil
        Task { @MainActor in
            await Task.yield()
            fileEditContext = repairContext
        }
    }

    private func beginExternalReview(
        projectID: UUID,
        rootPath: String,
        report: ProjectValidationReport,
        analysis: BuildFailureAnalysis?
    ) {
        validationContext = nil
        fileEditContext = nil
        Task { @MainActor in
            await Task.yield()
            externalReviewContext = ExternalReviewContext(
                projectID: projectID,
                rootPath: rootPath,
                report: report,
                analysis: analysis
            )
        }
    }

    private func beginRestore(_ record: ProjectRecord) {
        guard !record.project.fileCheckpoints.isEmpty else { return }
        restoreContext = RestoreContext(
            projectID: record.id,
            checkpoints: record.project.fileCheckpoints
        )
    }

}
