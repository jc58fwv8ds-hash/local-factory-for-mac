import Foundation
import HarnessCore

extension WorkspaceStore {
    @discardableResult
    func handoffPrimaryInstructionToComputerOperator(
        _ submittedInstruction: String
    ) -> Bool {
        guard let record = library.selectedRecord else {
            presentNotice("Local Factoryでプロジェクトを選択してください", kind: .information)
            return false
        }
        guard record.project.selectedModel != nil else {
            presentNotice("操作案を作るAIモデルを先に選択してください", kind: .information)
            isShowingModelManager = true
            return false
        }
        guard allowInteraction(.prepareComputerOperation) else { return false }

        switch computerOperator.prepareInstruction(
            submittedInstruction,
            for: record.project
        ) {
        case .busy:
            presentNotice("Computer Operatorが別の操作を準備中です", kind: .information)
            isShowingComputerOperator = true
            return false
        case .recoveryRequired:
            presentNotice("中断した操作を先に確認してください", kind: .information)
            isShowingComputerOperator = true
            return false
        case .ready:
            replySuggestions.cancel()
            isShowingComputerOperator = true
            computerOperator.makePlan(
                project: record.project,
                rootPath: record.sourceLocation
            )
            presentNotice(
                "テストや検索をComputer Operatorへ引き継ぎました",
                kind: .information
            )
            return true
        }
    }
}
