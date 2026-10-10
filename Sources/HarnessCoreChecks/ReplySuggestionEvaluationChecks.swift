import Foundation
import HarnessCore

/// Opt-in synthetic comparison. Neither arm reads or mutates the saved workspace.
enum ReplySuggestionEvaluationChecks {
    private struct Scenario {
        let id: String
        let conversation: [ConversationMessage]
        let criteria: [String]
    }

    static func run() async throws {
        let entry = try require(ModelCatalogEntry.recommended.first)
        let identifier = try require(entry.identifier(for: .ollama))
        let model = ModelSelection(identifier: identifier, displayName: entry.displayName, runtime: .ollama)
        let inference = LocalInferenceService()
        let requestedMode = ProcessInfo.processInfo.environment["HARNESS_REPLY_SUGGESTIONS_EVAL_MODE"] ?? "both"
        try expect(["both", "reply-suggestions"].contains(requestedMode), "Unknown reply evaluation mode")
        let modes = requestedMode == "both" ? ["ordinary-conversation", "reply-suggestions"] : ["reply-suggestions"]
        var failures = 0
        for scenario in scenarios {
            let project = HarnessProject(
                name: "頼み方の合成評価", summary: "個人用の日記アプリ（初期はクラウド案）",
                targets: [.macOS, .iPhone], stage: .design, progress: 0,
                currentActivity: "案の相談", workItems: [], activity: [],
                selectedModel: model, conversation: scenario.conversation
            )
            for mode in modes {
                let start = Date()
                var output = ""
                var failure: String?
                do {
                    if mode == "ordinary-conversation" {
                        var baseline = project
                        baseline.conversation.append(user("この話を次にどう進めるか、僕が送れる頼み方を2〜3個考えて。それぞれ何が分かるかも短く教えてね。まだ実行しないで。"))
                        output = try await collect(InferenceRequest(
                            runtime: .ollama, modelIdentifier: identifier,
                            messages: ProjectPromptBuilder.messages(for: baseline),
                            maximumOutputTokens: InferenceOutputBudget.conversation
                        ), inference: inference)
                    } else {
                        let context = try require(ReplySuggestionContext(project: project))
                        let choices = try await ReplySuggestionService(inference: inference).suggestions(for: context)
                        output = choices.map { "\($0.title)\n頼み方: \($0.instruction)\n見込み: \($0.effect)" }.joined(separator: "\n\n")
                    }
                } catch {
                    failure = error.localizedDescription
                    failures += 1
                }
                let report = Report(
                    scenario: scenario.id, mode: mode, model: identifier,
                    seconds: Date().timeIntervalSince(start), output: output, error: failure,
                    criteria: scenario.criteria
                )
                FileHandle.standardOutput.write(try JSONEncoder().encode(report) + Data("\n".utf8))
            }
        }
        try expect(failures == 0, "Reply suggestion evaluation failed; inspect outputs")
        print("Outputs collected; this is not an automatic semantic quality pass or a usability study.")
    }

    private static var scenarios: [Scenario] {
        var revised = [
            user("録音をクラウドで日記にしてiPhoneに残す案がいいな"),
            answer("クラウド処理とiPhone保存の案にします。"),
            user("やっぱり外に送らずMacだけで処理して。iPhoneは中継だけで、届いた分はiPhoneから消す案に変更ね。まだファイルは変えないで。"),
            answer("Macで処理し、iPhoneは中継に限る設計案だね。")
        ]
        for topic in ["文字の大きさ", "一覧", "検索", "タイトル", "夜の色", "転送中の表示"] {
            revised += [user("\(topic)も分かりやすくしてね"), answer("\(topic)を調整する案だね。")]
        }
        return [
            Scenario(id: "revised-scope", conversation: revised, criteria: [
                "候補が古いクラウド処理・iPhone永続保存を復活させない",
                "説明・検討の候補に留め、実行や変更済みとしない",
                "各案の違いが分かり、ユーザーがそのまま言えそうな短い日本語"
            ]),
            Scenario(id: "two-explicit-options", conversation: [
                user("保存するものを減らす案を考えて。勝手には消さないでね。"),
                answer("案Aは古い録音だけを消して文章を残す方法、案Bは録音と文章をまとめて消す方法だよ。")
            ], criteria: [
                "元の2案の対象差が保たれ、架空の第三案を増やさない",
                "提案は削除の実行・承認済みという主張ではない",
                "見込みを説明し、自然な頼み方として選べる"
            ])
        ]
    }

    private static func collect(_ request: InferenceRequest, inference: any ModelInferenceProvider) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var output = ""
                for try await part in await inference.events(for: request) {
                    try Task.checkCancellation()
                    guard output.count + part.count <= 16_000 else { throw InferenceError.invalidResponse }
                    output += part
                }
                try Task.checkCancellation()
                return output
            }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                throw CheckFailure(description: "Baseline exceeded 180 seconds")
            }
            defer { group.cancelAll() }
            return try await require(group.next())
        }
    }

    private static func user(_ text: String) -> ConversationMessage { ConversationMessage(role: .user, content: text) }
    private static func answer(_ text: String) -> ConversationMessage { ConversationMessage(role: .assistant, content: text) }

    private struct Report: Encodable {
        let scenario: String
        let mode: String
        let model: String
        let seconds: Double
        let output: String
        let error: String?
        let criteria: [String]
    }
}
