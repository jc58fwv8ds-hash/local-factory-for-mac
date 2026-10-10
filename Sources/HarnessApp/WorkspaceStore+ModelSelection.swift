import HarnessCore

extension WorkspaceStore {
    func selectModel(_ model: InstalledModel) {
        library.updateSelectedProject { project in
            project.selectedModel = ModelSelection(
                identifier: model.identifier,
                displayName: model.displayName,
                runtime: model.runtime,
                capabilities: model.capabilities
            )
            project.currentActivity = "\(model.displayName)を使う準備ができました"
            project.activity.insert(
                ActivityEvent(
                    title: "AIモデルを選択しました",
                    detail: "\(model.displayName) ・ \(model.runtime.rawValue)",
                    kind: .verification
                ),
                at: 0
            )
        }
        persist(successMessage: "AIモデルを接続しました")
    }

    func disconnectModel() {
        if isGeneratingSelectedProject {
            stopGeneration()
        }
        library.updateSelectedProject { project in
            project.selectedModel = nil
            project.currentActivity = "AIモデルの接続を待っています"
        }
        persist(successMessage: "AIモデルの接続を解除しました")
    }
}
