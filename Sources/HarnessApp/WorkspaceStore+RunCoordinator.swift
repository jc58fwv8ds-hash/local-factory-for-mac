import HarnessCore

extension WorkspaceStore {
    func beginNextRunItem() -> RunCoordinatorWorkSelection? {
        prepareRunItem(resumesCurrent: false)
    }

    func resumeCurrentRunItem() -> RunCoordinatorWorkSelection? {
        prepareRunItem(resumesCurrent: true)
    }

    func approveCurrentRunItem() {
        guard let projectID = library.selectedProjectID else { return }
        var didApprove = false
        library.updateProject(projectID) { project in
            didApprove = RunCoordinatorWorkflow.approveCurrent(in: &project)
        }
        guard didApprove else {
            presentNotice("検証済みの制作項目を確認できませんでした", kind: .information)
            return
        }
        persist(successMessage: "1項目を確認済みにしました。次へ進めます")
    }

    func pauseRunCoordinator() {
        guard let projectID = library.selectedProjectID else { return }
        library.updateProject(projectID) { project in
            RunCoordinatorWorkflow.pause(in: &project)
        }
        persist(successMessage: "連続制作を一時停止しました")
    }

    private func prepareRunItem(
        resumesCurrent: Bool
    ) -> RunCoordinatorWorkSelection? {
        guard let record = library.selectedRecord else {
            presentNotice("プロジェクトを選んでね", kind: .information)
            return nil
        }
        guard record.sourceLocation != nil else {
            presentNotice("先に制作するソースフォルダを接続してね", kind: .information)
            return nil
        }
        guard record.project.selectedModel != nil else {
            presentNotice("制作に使うAIモデルを先に選んでね", kind: .information)
            isShowingModelManager = true
            return nil
        }

        var decision = RunCoordinatorDecision.stopped(.workItemUnavailable)
        library.updateProject(record.id) { project in
            decision = resumesCurrent
                ? RunCoordinatorWorkflow.resumeCurrent(in: &project)
                : RunCoordinatorWorkflow.beginNext(in: &project)
        }
        switch decision {
        case .selected(let selection):
            persist(successMessage: "「\(selection.title)」を1項目ずつ進めます")
            return selection
        case .readyForFinalValidation:
            persist(successMessage: "全項目の最終検証へ進めます")
            return nil
        case .stopped(let blocker):
            persist()
            presentNotice(blocker.guidance, kind: .information)
            return nil
        }
    }
}
