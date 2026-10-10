import Foundation
import HarnessCore

extension WorkspaceStore {
    func setCreationLoopReviewMode(_ mode: CreationLoopReviewMode) {
        guard let projectID = library.selectedProjectID else { return }
        library.updateProject(projectID) { project in
            CreationLoopWorkflow.select(reviewMode: mode, in: &project)
            project.activity.insert(
                ActivityEvent(
                    title: "制作ループを切り替えました",
                    detail: mode.displayName,
                    kind: .information
                ),
                at: 0
            )
        }
        persist(successMessage: "\(mode.displayName)を使用します")
    }

    func completeCreationLoop() {
        guard let projectID = library.selectedProjectID else { return }
        let readiness = CreationCompletionPolicy.readiness(for: project)
        guard readiness.isReady else {
            presentNotice(
                readiness.guidance ?? "完成にする前に現在の状態を確認してね。",
                kind: .information
            )
            return
        }
        library.updateProject(projectID) { project in
            CreationLoopWorkflow.completed(in: &project)
        }
        persist(successMessage: "制作ループを完成として終了しました")
    }

    func recordExternalReview(_ response: String, projectID: UUID) {
        library.updateProject(projectID) { project in
            CreationLoopWorkflow.importedExternalReview(
                response: response,
                in: &project
            )
        }
        persist(successMessage: "ChatGPTレビューを取り込みました")
    }

    func recordFileEditGeneration(
        _ event: FileEditGenerationEvent,
        projectID: UUID
    ) {
        library.updateProject(projectID) { project in
            switch event {
            case let .started(instruction):
                ProjectFileEditInferenceWorkflow.started(
                    instruction: instruction,
                    in: &project
                )
            case .proposalReady:
                ProjectFileEditInferenceWorkflow.proposalReady(in: &project)
            case .cancelled:
                ProjectFileEditInferenceWorkflow.cancelled(in: &project)
            case let .failed(message):
                ProjectFileEditInferenceWorkflow.failed(
                    message: message,
                    in: &project
                )
            }
        }
        persist()
    }

    func recordArtifactPlanGeneration(
        _ event: ArtifactPlanGenerationEvent,
        projectID: UUID
    ) {
        library.updateProject(projectID) { project in
            switch event {
            case .started:
                ArtifactCreationPlanWorkflow.planningStarted(in: &project)
            case .planReady:
                ArtifactCreationPlanWorkflow.planningReady(in: &project)
            case .cancelled:
                ArtifactCreationPlanWorkflow.planningCancelled(in: &project)
            case let .failed(message):
                ArtifactCreationPlanWorkflow.planningFailed(
                    message: message,
                    in: &project
                )
            }
        }
        persist()
    }

    func recordArtifactPlanStarted(_ plan: ArtifactCreationPlan, projectID: UUID) {
        library.updateProject(projectID) { project in
            ArtifactCreationPlanWorkflow.started(plan: plan, in: &project)
        }
        persist(successMessage: "成果物計画を開始しました")
    }

    func recordArtifactPlanProgress(_ plan: ArtifactCreationPlan, projectID: UUID) {
        library.updateProject(projectID) { project in
            ArtifactCreationPlanWorkflow.updated(plan: plan, in: &project)
        }
        persist()
    }
}
