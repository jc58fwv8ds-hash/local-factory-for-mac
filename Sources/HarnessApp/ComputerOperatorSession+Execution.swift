import Foundation
import HarnessCore

extension ComputerOperatorSession {
    func execute(
        _ step: ComputerOperationStep,
        rootPath: String?
    ) async -> ComputerOperationResult {
        do {
            switch step.kind {
            case .projectValidation:
                guard let rootPath else {
                    throw ComputerOperationExecutionError.sourceNotConnected
                }
                let report = try await validationProvider.validate(rootPath: rootPath)
                let detail = report.checks.map {
                    "\($0.kind.displayName): \($0.succeeded ? "成功" : "失敗")"
                }.joined(separator: "・")
                return result(step, report.succeeded, detail, detail)
            case .webSearch:
                return try await executeWebSearch(step)
            case .inspectApplication:
                let elements = try controller.inspect(application: step.application ?? "")
                let message = elements.prefix(20).map {
                    "\($0.role): \($0.label)"
                }.joined(separator: "\n")
                return result(
                    step,
                    true,
                    message.isEmpty ? "読み取れる項目はありませんでした。" : message,
                    "指定したアプリをローカルで読み取りました。画面内の生データはAI要約へ渡していません。"
                )
            case .pressButton:
                try controller.pressButton(
                    application: step.application ?? "",
                    label: step.element ?? ""
                )
                return result(
                    step,
                    true,
                    "指定された安全なボタンを1回押しました。",
                    "確認済みの開発用ボタンを1回操作しました。"
                )
            }
        } catch {
            return result(
                step,
                false,
                error.localizedDescription,
                "操作はエラーで停止しました：\(String(error.localizedDescription.prefix(500)))"
            )
        }
    }

    func executeWebSearch(
        _ step: ComputerOperationStep
    ) async throws -> ComputerOperationResult {
        let search = try controller.openWebSearch(step.query ?? "")
        guard controller.hasAccessibilityPermission else {
            let detail = "検索ページは開きました。公開結果の自動読取にはmacOSのアクセシビリティ許可が必要です。"
            return result(step, true, detail, detail)
        }
        var publicResults: [PublicWebSearchResult] = []
        for _ in 0..<3 where publicResults.isEmpty {
            try await Task.sleep(for: .seconds(1))
            publicResults = try controller.readPublicSearchResults(from: search)
        }
        guard !publicResults.isEmpty else {
            let detail = "検索ページは開きましたが、公開結果の読取はまだ完了していません。ブラウザの表示後にもう一度お試しください。"
            return result(step, true, detail, detail)
        }
        let links = publicResults.map {
            "• \($0.title)\n  \($0.urlString)"
        }.joined(separator: "\n")
        let detail = "公開検索結果を\(publicResults.count)件読み取りました。\n\(links)"
        return result(step, true, detail, detail)
    }

    func summarizeResults(project: HarnessProject) async {
        guard let plan, let model = project.selectedModel else { return }
        isSummarizing = true
        let messages = ComputerOperationResultSummaryPromptBuilder.messages(
            instruction: instruction,
            plan: plan,
            evidence: results.map(\.summaryEvidence)
        )
        let request = InferenceRequest(
            runtime: model.runtime,
            modelIdentifier: model.identifier,
            messages: messages,
            maximumOutputTokens: InferenceOutputBudget.computerSummary
        )
        do {
            var response = ""
            let events = await inferenceProvider.events(for: request)
            for try await delta in events {
                try Task.checkCancellation()
                response += delta
            }
            try Task.checkCancellation()
            let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
            resultSummary = cleaned.isEmpty ? fallbackSummary : cleaned
        } catch is CancellationError {
            resultSummary = nil
        } catch {
            resultSummary = fallbackSummary
        }
        isSummarizing = false
    }

    var fallbackSummary: String {
        results.last?.succeeded == false
            ? "今は操作の途中でエラーが見つかり、そこで安全に停止しています。履歴の内容を直してから再実行すると、残りの確認へ進めます。"
            : "予定した操作は完了しました。検索結果とテスト結果は履歴から確認できます。"
    }

    func result(
        _ step: ComputerOperationStep,
        _ succeeded: Bool,
        _ message: String,
        _ evidence: String
    ) -> ComputerOperationResult {
        ComputerOperationResult(
            step: step,
            succeeded: succeeded,
            message: message,
            summaryEvidence: ComputerOperationEvidence(
                kind: step.kind,
                succeeded: succeeded,
                detail: evidence
            )
        )
    }
}

private enum ComputerOperationExecutionError: LocalizedError {
    case sourceNotConnected

    var errorDescription: String? {
        "プロジェクトへソースフォルダが接続されていません。"
    }
}
