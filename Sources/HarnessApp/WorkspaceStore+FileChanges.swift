import Foundation
import HarnessCore

extension WorkspaceStore {
    func recordAppliedFileChange(
        _ change: AppliedFileChange,
        projectID: UUID
    ) {
        var expiredCheckpoint: GitFileCheckpoint?
        library.updateProject(projectID) { project in
            expiredCheckpoint = ProjectFileChangeWorkflow.applied(
                proposal: change.proposal,
                checkpoint: change.checkpoint,
                in: &project
            )
            RunCoordinatorWorkflow.recordedChange(in: &project)
        }
        if let expiredCheckpoint {
            Task { await gitCheckpointProvider.discard(expiredCheckpoint) }
        }
        let message: String
        if change.proposal.operation == .creation {
            message = "レビュー済みの新規ファイルを作成しました"
        } else if change.checkpoint == nil {
            message = "レビュー済みの変更を保存しました"
        } else {
            message = "変更を保存し、Git復元ポイントを作成しました"
        }
        persist(successMessage: message)
        inspectSource(for: projectID, announcesCompletion: false, detectsChanges: false)
    }

    func recordRevertedFileChange(
        _ change: AppliedFileChange,
        projectID: UUID
    ) {
        library.updateProject(projectID) { project in
            ProjectFileChangeWorkflow.reverted(
                proposal: change.proposal,
                checkpoint: change.checkpoint,
                in: &project
            )
            RunCoordinatorWorkflow.recordedChange(in: &project)
        }
        persist(successMessage: change.proposal.operation == .creation
            ? "新規ファイルの作成を元に戻しました"
            : "ファイル変更を元に戻しました")
        inspectSource(for: projectID, announcesCompletion: false, detectsChanges: false)
    }

    func recordRestoredCheckpoint(
        _ checkpoint: GitFileCheckpoint,
        projectID: UUID
    ) {
        library.updateProject(projectID) { project in
            ProjectFileChangeWorkflow.restored(checkpoint: checkpoint, in: &project)
            RunCoordinatorWorkflow.recordedChange(in: &project)
        }
        persist(successMessage: "Git復元ポイントからファイルを戻しました")
        inspectSource(for: projectID, announcesCompletion: false, detectsChanges: false)
    }

    func recordValidation(
        _ report: ProjectValidationReport,
        projectID: UUID
    ) {
        var freshPlan: BuildRepairPlan?
        var failureAnalysis: BuildFailureAnalysis?
        if !report.succeeded,
           let rootPath = library.records.first(where: { $0.id == projectID })?.sourceLocation {
            failureAnalysis = BuildFailureAnalyzer.analyze(
                report: report,
                rootPath: rootPath
            )
            if let failureAnalysis,
               ValidationFailureClassifier.classify(
                   report: report,
                   analysis: failureAnalysis
               ).permitsCodeChanges {
                freshPlan = failureAnalysis.repairPlan
            }
        }
        library.updateProject(projectID) { project in
            ProjectOperationCheckpointWorkflow.completed(
                .projectValidation,
                in: &project
            )
            ProjectValidationWorkflow.completed(report: report, in: &project)
            ArtifactCreationPlanWorkflow.validationCompleted(
                report: report,
                in: &project
            )
            RepairResumeWorkflow.validationCompleted(
                report: report,
                freshPlan: freshPlan,
                in: &project
            )
            RunCoordinatorWorkflow.recordedValidation(
                report,
                analysis: failureAnalysis,
                in: &project
            )
        }
        persist(
            successMessage: report.succeeded
                ? report.system == .xcode
                    ? "Xcodeのビルドとテストに合格しました"
                    : "ビルドとテストに合格しました"
                : nil
        )
        if !report.succeeded {
            presentNotice("検証結果を確認してください", kind: .information)
        }
    }

    func recordValidationStarted(projectID: UUID) {
        library.updateProject(projectID) { project in
            CreationLoopWorkflow.startedValidation(in: &project)
            if project.artifactCreationPlan?.isFullyApplied == true {
                project.currentActivity = "成果物計画の最終検証を実行しています"
            }
            ProjectOperationCheckpointWorkflow.started(
                .projectValidation,
                in: &project
            )
        }
        persist()
    }

    func discardOperationCheckpoint(projectID: UUID) {
        library.updateProject(projectID) { project in
            if project.operationCheckpoint?.operation == .fileEditInference {
                ProjectFileEditInferenceWorkflow.discardedInterruptedGeneration(
                    in: &project
                )
            } else if project.operationCheckpoint?.operation == .artifactPlanning {
                ArtifactCreationPlanWorkflow.discardedInterruptedPlanning(in: &project)
            } else {
                ProjectOperationCheckpointWorkflow.discarded(in: &project)
            }
        }
        persist(successMessage: "中断した処理記録を破棄しました。ソースは変更していません")
    }

    func discardArtifactCreationPlan(projectID: UUID) {
        library.updateProject(projectID) { project in
            ArtifactCreationPlanWorkflow.discarded(in: &project)
        }
        persist(successMessage: "成果物計画を破棄しました。作成済みファイルは変更していません")
    }

    func recordRepairPlan(
        _ plan: BuildRepairPlan,
        selectedTargetID: String,
        projectID: UUID
    ) {
        library.updateProject(projectID) { project in
            RepairResumeWorkflow.started(
                plan: plan,
                selectedTargetID: selectedTargetID,
                in: &project
            )
        }
        persist()
    }

    func recordRepairProgress(
        _ progress: BuildRepairProgress,
        projectID: UUID
    ) {
        library.updateProject(projectID) { project in
            RepairResumeWorkflow.updated(progress: progress, in: &project)
        }
        persist()
    }

    func discardRepairResumeState(projectID: UUID) {
        library.updateProject(projectID) { project in
            RepairResumeWorkflow.discarded(in: &project)
        }
        persist(successMessage: "中断中の修正記録を破棄しました。ソースは変更していません")
    }
}
