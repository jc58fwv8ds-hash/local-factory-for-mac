import Foundation

public enum ProjectInferenceWorkflow {
    @discardableResult
    public static func accept(
        instruction: String,
        workItemID: UUID,
        origin: ConversationOrigin = .user,
        visualAttachments: [VisualAttachmentDescriptor] = [],
        in project: inout HarnessProject
    ) -> UUID {
        ProjectInstructionAcceptance.accept(
            instruction: instruction,
            proposedWorkItemID: workItemID,
            origin: origin,
            visualAttachments: visualAttachments,
            in: &project
        )
    }

    public static func preparedSourceContext(
        _ snapshot: SourceContextSnapshot,
        in project: inout HarnessProject
    ) {
        preparedSourceContext(
            SourceContextSelection(
                snapshot: snapshot,
                strategy: .allAvailable,
                originalFileCount: snapshot.files.count,
                originalCharacterCount: snapshot.totalCharacters
            ),
            in: &project
        )
    }

    public static func preparedSourceContext(
        _ selection: SourceContextSelection,
        in project: inout HarnessProject
    ) {
        let detail: String
        switch selection.strategy {
        case .allAvailable:
            guard let snapshot = selection.snapshot, !snapshot.files.isEmpty else { return }
            project.currentActivity = "\(snapshot.files.count)ファイルを読み取り、AIへ渡す準備ができました"
            detail = "読み取り専用 ・ \(snapshot.files.count)ファイル ・ \(snapshot.totalCharacters)文字"
        case .focused:
            guard let snapshot = selection.snapshot, !snapshot.files.isEmpty else { return }
            project.currentActivity = "関係する\(snapshot.files.count)ファイルを優先してAIへ渡します"
            detail = "読み取り専用 ・ \(selection.originalFileCount)ファイルから\(snapshot.files.count)ファイルを優先 ・ \(snapshot.totalCharacters)文字"
        case .omittedForResponseRevision:
            project.currentActivity = "今の会話だけで回答する準備ができました"
            detail = "返答の言い直しなので、ソース本文はAIへ渡していません"
        }
        project.activity.insert(
            ActivityEvent(
                title: "ソースコンテキストを準備しました",
                detail: detail,
                kind: .information
            ),
            at: 0
        )
    }

    public static func sourceContextUnavailable(
        message: String,
        in project: inout HarnessProject
    ) {
        project.activity.insert(
            ActivityEvent(
                title: "ソースコンテキストを使えませんでした",
                detail: "モデルとの会話はプロジェクト情報だけで続けます。\(message)",
                kind: .warning
            ),
            at: 0
        )
    }

    public static func complete(
        response: String,
        model: ModelSelection,
        workItemID: UUID,
        in project: inout HarnessProject
    ) {
        CreationLoopWorkflow.consultationReady(in: &project)
        project.conversation.append(
            ConversationMessage(
                role: .assistant,
                content: response,
                modelName: model.displayName
            )
        )
        project.currentActivity = "\(model.displayName)から提案を受け取りました"
        updateWorkItem(workItemID, status: .completed, in: &project)
        project.activity.insert(
            ActivityEvent(
                title: "AIの応答を受け取りました",
                detail: "\(model.displayName) ・ \(response.prefix(180))",
                kind: .information
            ),
            at: 0
        )
    }

    @discardableResult
    public static func resume(
        workItemID: UUID,
        model: ModelSelection,
        in project: inout HarnessProject
    ) -> Bool {
        guard let index = project.workItems.firstIndex(where: {
            $0.id == workItemID
        }) else { return false }
        CreationLoopWorkflow.resumedConsultation(in: &project)
        project.workItems[index].status = .active
        project.currentActivity = "\(model.displayName)が指示をもう一度確認しています"
        project.activity.insert(
            ActivityEvent(
                title: "AIの応答を再実行しました",
                detail: "保存済みの指示を重複追加せず、最初から生成します",
                kind: .information
            ),
            at: 0
        )
        return true
    }

    public static func cancel(workItemID: UUID, in project: inout HarnessProject) {
        CreationLoopWorkflow.cancelled(in: &project)
        project.currentActivity = "AIの生成を停止しました"
        updateWorkItem(workItemID, status: .needsAttention, in: &project)
        project.activity.insert(
            ActivityEvent(
                title: "AIの生成を停止しました",
                detail: "途中の応答は保存せず、指示を確認待ちに戻しました",
                kind: .warning
            ),
            at: 0
        )
    }

    public static func fail(
        message: String,
        model: ModelSelection,
        workItemID: UUID,
        in project: inout HarnessProject
    ) {
        CreationLoopWorkflow.failed(in: &project)
        project.currentActivity = "AIから新しい提案を受け取れませんでした"
        updateWorkItem(workItemID, status: .needsAttention, in: &project)
        project.activity.insert(
            ActivityEvent(
                title: "AIの実行に失敗しました",
                detail: "\(model.displayName) ・ \(message)",
                kind: .warning
            ),
            at: 0
        )
    }

    private static func updateWorkItem(
        _ id: UUID,
        status: WorkStatus,
        in project: inout HarnessProject
    ) {
        guard let index = project.workItems.firstIndex(where: { $0.id == id }) else { return }
        project.workItems[index].status = status
    }
}
