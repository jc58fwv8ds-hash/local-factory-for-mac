import Foundation

public enum ProjectFileEditInferenceWorkflow {
    public static func started(
        instruction: String,
        in project: inout HarnessProject
    ) {
        CreationLoopWorkflow.acceptedInstruction(in: &project)
        ProjectOperationCheckpointWorkflow.started(
            .fileEditInference,
            in: &project
        )
        project.currentActivity = "ローカルモデルがファイル変更案を作っています"
        project.activity.insert(
            ActivityEvent(
                title: "ファイル編集指示を受け付けました",
                detail: String(instruction.prefix(180)),
                kind: .instruction
            ),
            at: 0
        )
    }

    public static func proposalReady(in project: inout HarnessProject) {
        CreationLoopWorkflow.localProposalReady(in: &project)
        ProjectOperationCheckpointWorkflow.completed(
            .fileEditInference,
            in: &project
        )
        project.currentActivity = "AIのファイル変更案を確認してください"
    }

    public static func cancelled(in project: inout HarnessProject) {
        CreationLoopWorkflow.cancelled(in: &project)
        ProjectOperationCheckpointWorkflow.completed(
            .fileEditInference,
            in: &project
        )
        project.currentActivity = "ファイル変更案の生成を停止しました"
    }

    public static func failed(
        message: String,
        in project: inout HarnessProject
    ) {
        CreationLoopWorkflow.failed(in: &project)
        ProjectOperationCheckpointWorkflow.completed(
            .fileEditInference,
            in: &project
        )
        project.currentActivity = "ファイル変更案を生成できませんでした"
        project.activity.insert(
            ActivityEvent(
                title: "ファイル変更案の生成に失敗しました",
                detail: String(message.prefix(180)),
                kind: .warning
            ),
            at: 0
        )
    }

    public static func discardedInterruptedGeneration(
        in project: inout HarnessProject
    ) {
        guard project.operationCheckpoint?.operation == .fileEditInference else {
            return
        }
        CreationLoopWorkflow.cancelled(in: &project)
        ProjectOperationCheckpointWorkflow.completed(
            .fileEditInference,
            in: &project
        )
        project.currentActivity = "中断したファイル変更案を破棄しました"
    }
}
