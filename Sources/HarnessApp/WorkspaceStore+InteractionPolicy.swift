import HarnessCore

extension WorkspaceStore {
    var workspaceInteractionState: WorkspaceInteractionState {
        WorkspaceInteractionState(
            isGenerating: isGenerating,
            isVoiceConversationActive: voiceConversation.isActive,
            isComputerOperatorBusy: computerOperator.isBusy,
            hasResumableProjectWork: project.operationCheckpoint != nil,
            hasPendingComputerOperation: project.computerOperationCheckpoint != nil
        )
    }

    func interactionBlocker(
        for operation: WorkspaceInteractionOperation
    ) -> WorkspaceInteractionBlocker? {
        WorkspaceInteractionPolicy.blocker(
            for: operation,
            state: workspaceInteractionState
        )
    }

    func interactionMessage(for blocker: WorkspaceInteractionBlocker) -> String {
        switch blocker {
        case .modelGeneration:
            "別のAI応答を生成中です。完了後にもう一度送ってください"
        case .voiceConversation:
            "ボイスモードを終了してから試してね"
        case .computerOperator:
            "Computer Operatorの処理が終わってから試してね"
        case .resumableProjectWork:
            "中断した作業を再開するか破棄してから試してね"
        case .pendingComputerOperation:
            "確認待ちのComputer操作を再開するか破棄してから試してね"
        }
    }

    @discardableResult
    func allowInteraction(
        _ operation: WorkspaceInteractionOperation,
        presentsNotice: Bool = true
    ) -> Bool {
        guard let blocker = interactionBlocker(for: operation) else { return true }
        if presentsNotice {
            presentNotice(interactionMessage(for: blocker), kind: .information)
        }
        return false
    }

    func openComputerOperator() {
        guard allowInteraction(.openComputerOperator) else { return }
        isShowingComputerOperator = true
    }

    func makeComputerOperatorPlan() {
        guard allowInteraction(.prepareComputerOperation) else { return }
        computerOperator.makePlan(
            project: project,
            rootPath: library.selectedRecord?.sourceLocation
        )
    }

    func executeComputerOperatorPlan() {
        guard allowInteraction(.executeComputerOperation) else { return }
        computerOperator.execute(
            project: project,
            rootPath: library.selectedRecord?.sourceLocation
        )
    }
}
