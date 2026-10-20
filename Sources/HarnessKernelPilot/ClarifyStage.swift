import Foundation
import HarnessCore
import TaskOrchestrator

/// Candidate 3 (2026-10-18): before building, the builder names the points where the request and the code allow readings
/// that give different results, and the answers are added to the request. Two ways to answer, for measuring:
/// - `self`: the builder decides each point from the code (usable with no one to ask);
/// - `oracle`: a stand-in for the user who knows the intended behaviour (the task's reference solution) answers only the
///   question asked, in one sentence. This is the ceiling of "ask the user", not something the builder ever sees directly.
enum ClarifyStage {
    typealias Point = ClarifyQuestions.Point
    /// The two raw responses of the last run, kept for the measurement record.
    nonisolated(unsafe) static var lastRaw: [String] = []

    static func clarify(objective: String, files: [String: String], protected: [String], model: String,
                        mode: String, reference: [String: String]) async throws -> [Point] {
        let sources = files.filter { $0.key.hasSuffix(".swift") && !protected.contains($0.key) && !$0.key.hasPrefix("Tests/") }
            .sorted { $0.key < $1.key }.map { "--- \($0.key)\n\($0.value)" }.joined(separator: "\n")
        let ask = ClarifyQuestions.prompt(objective: objective, sources: files
            .filter { $0.key.hasSuffix(".swift") && !protected.contains($0.key) && !$0.key.hasPrefix("Tests/") }
            .sorted { $0.key < $1.key }.map { (path: $0.key, content: $0.value) })
        let raw = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
            messages: [.init(role: .user, content: ask)], maximumOutputTokens: 1024, temperature: 0))
        lastRaw = [raw]
        let questions = ClarifyQuestions.questions(in: raw)
        guard !questions.isEmpty else { return [] }
        let numbered = questions.enumerated().map { "Q\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        let prompt: String
        if mode == "oracle" {
            let intended = reference.sorted { $0.key < $1.key }.map { "--- \($0.key)\n\($0.value)" }.joined(separator: "\n")
            prompt = """
            あなたはこの依頼をした利用者です。望んでいる完成形は下の「完成形のコード」と「(作者のメモ)」のとおりです。\
            答える前に、問いに関係するコードの箇所(順序・条件・対象)を自分で確かめてください。\
            開発者からの問いに、利用者として、問われたことだけを 1 文で答えてください。コードや関数名は書かず、\
            問われていない決まりは付け足さないでください。完成形で決まらない問いには「おまかせします」と答えます。
            問いの言い方に合わせず、完成形が実際にどう動くかで答えます(問いの前提が完成形と違えば「いいえ」と正しい内容を答える)。
            書き方: 問いごとに、まず「確認1: 」の行に完成形の該当箇所の動き(順序・条件)を 1 行で書き、次の行に「A1: 答え」。

            依頼: \(objective)

            完成形のコード:
            \(intended)

            問い:
            \(numbered)
            """
        } else {
            prompt = """
            次の依頼について、迷う点をコードから決めてください。コメント・既存の関数・既存の決まりを根拠に、\
            それぞれ 1 文で結論を書きます(根拠のファイル名を括弧で添える)。根拠がなければ、依頼の文に最も素直な読み方を選びます。
            書き方: 「A1: …」のように問いの番号ごとに 1 行。

            依頼: \(objective)

            コード:
            \(sources)

            問い:
            \(numbered)
            """
        }
        let answered = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
            messages: [.init(role: .user, content: prompt)], maximumOutputTokens: 1024, temperature: 0))
        lastRaw.append(answered)
        let answers = answers(in: answered)
        return questions.enumerated().compactMap { index, question in
            answers[index + 1].map { Point(question: question, answer: $0) }
        }
    }

    /// The answers by their numbers when every number is different; in the order written when the model repeats one
    /// (2026-10-18: all 「A1」; 2026-10-20 c3-08: answers out of order, so order alone mismatched them).
    static func answers(in text: String) -> [Int: String] {
        var numbered: [(Int?, String)] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: #"^A(\d*)[:：]\s*"#, options: .regularExpression) else { continue }
            let answer = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !answer.isEmpty else { continue }
            numbered.append((Int(trimmed[range].filter(\.isNumber)), answer))
        }
        let numbers = numbered.compactMap(\.0)
        if numbers.count == numbered.count, Set(numbers).count == numbers.count {
            return Dictionary(uniqueKeysWithValues: numbered.map { ($0.0!, $0.1) })
        }
        return Dictionary(uniqueKeysWithValues: numbered.enumerated().map { ($0.offset + 1, $0.element.1) })
    }
}
