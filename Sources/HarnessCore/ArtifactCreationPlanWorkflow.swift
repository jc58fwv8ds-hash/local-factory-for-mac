import Foundation

public enum ArtifactCreationPlanWorkflow {
    public static func planningStarted(
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        CreationLoopWorkflow.acceptedInstruction(in: &project, now: now)
        ProjectOperationCheckpointWorkflow.started(.artifactPlanning, in: &project, now: now)
        project.currentActivity = "ローカルAIが複数ファイルの成果物計画を作っています"
    }

    public static func planningReady(
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        ProjectOperationCheckpointWorkflow.completed(.artifactPlanning, in: &project)
        CreationLoopWorkflow.localProposalReady(in: &project, now: now)
        project.currentActivity = "成果物計画を確認してください"
    }

    public static func planningCancelled(in project: inout HarnessProject, now: Date = .now) {
        ProjectOperationCheckpointWorkflow.completed(.artifactPlanning, in: &project)
        CreationLoopWorkflow.cancelled(in: &project, now: now)
    }

    public static func planningFailed(
        message: String,
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        ProjectOperationCheckpointWorkflow.completed(.artifactPlanning, in: &project)
        CreationLoopWorkflow.failed(in: &project, now: now)
        project.currentActivity = "成果物計画を作成できませんでした"
        project.activity.insert(
            ActivityEvent(
                occurredAt: now,
                title: "成果物計画を作成できませんでした",
                detail: String(message.prefix(500)),
                kind: .warning
            ),
            at: 0
        )
    }

    public static func started(
        plan: ArtifactCreationPlan,
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        project.artifactCreationPlan = plan
        project.currentActivity = "\(plan.targets.count)ファイルの成果物計画を開始しました"
        project.activity.insert(
            ActivityEvent(
                occurredAt: now,
                title: "段階的な成果物計画を開始しました",
                detail: "一括保存せず、\(plan.targets.count)ファイルを1件ずつ確認します",
                kind: .instruction
            ),
            at: 0
        )
    }

    public static func updated(
        plan: ArtifactCreationPlan,
        in project: inout HarnessProject
    ) {
        guard project.artifactCreationPlan?.id == plan.id else { return }
        project.artifactCreationPlan = plan
    }

    public static func validationCompleted(
        report: ProjectValidationReport,
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        guard let plan = project.artifactCreationPlan, plan.isFullyApplied else { return }
        project.artifactCreationPlan = nil
        project.activity.insert(
            ActivityEvent(
                occurredAt: now,
                title: report.succeeded
                    ? "成果物計画の最終検証に合格しました"
                    : "成果物計画の最終検証で修正が必要です",
                detail: "\(plan.targets.count)ファイルの作成を検証しました",
                kind: report.succeeded ? .verification : .warning
            ),
            at: 0
        )
    }

    public static func discarded(in project: inout HarnessProject) {
        project.artifactCreationPlan = nil
    }

    public static func discardedInterruptedPlanning(in project: inout HarnessProject) {
        guard project.operationCheckpoint?.operation == .artifactPlanning else { return }
        ProjectOperationCheckpointWorkflow.discarded(in: &project)
        CreationLoopWorkflow.cancelled(in: &project)
    }
}
