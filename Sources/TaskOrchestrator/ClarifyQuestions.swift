import Foundation

/// Asking before building (2026-10-19, measured on C2): the builder names up to three points where the request and the code
/// allow readings with different results; a person answers them and the answers go with the request. Answered by a person
/// (a stand-in with the intended behaviour) the suite went 16 → 18 of 22 and false successes 3 → 1; answered by the builder
/// itself it fell to 12 and 4 (it agrees with its own leading questions), so only a person answers.
public enum ClarifyQuestions {
    public struct Point: Equatable, Sendable {
        public var question: String
        public var answer: String
        public init(question: String, answer: String) { self.question = question; self.answer = answer }
    }

    /// The prompt that asks for the questions. `sources`: path → content of the code the builder will read.
    public static func prompt(objective: String, sources: [(path: String, content: String)]) -> String {
        let code = sources.map { "--- \($0.path)\n\($0.content)" }.joined(separator: "\n")
        return """
        あなたはこれから次の依頼どおりにコードを変更します。変更を始める前に、依頼の文とコードを読んで、\
        読み方によって結果(値・表示・順序・対象)が変わってしまう点を最大 3 つ挙げてください。\
        コードのコメントや既存の決まりで答えが一つに決まるものは挙げないでください。迷う点がなければ「なし」とだけ書きます。
        書き方: 1 行に 1 つ、「Q: 」で始まる具体的な問い(はい/いいえ、またはどちらか、で答えられる形)。

        依頼: \(objective)

        コード:
        \(code)
        """
    }

    /// The questions in a response, at most three.
    public static func questions(in text: String) -> [String] {
        let found = text.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: #"^(\d+[.)]\s*)?Q\d*[:：]\s*"#, options: .regularExpression) else { return nil }
            let question = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return question.isEmpty ? nil : question
        }
        return Array(found.prefix(3))
    }

    /// The request with the answered points appended, as the builder sees it. Unanswered points add nothing.
    public static func objective(_ objective: String, with points: [Point]) -> String {
        let answered = points.filter { !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !answered.isEmpty else { return objective }
        return objective + "\n\n確認済みの点:\n" + answered.map { "・\($0.question) → \($0.answer)" }.joined(separator: "\n")
    }

    /// The user's own request without the appended points. Clause coverage is checked on this only (2026-10-20: counting
    /// each answered point as a clause the plan must cover stopped C3 runs at the plan stage, OBJECTIVE_CLAUSE_UNCOVERED).
    public static func request(of objective: String) -> String {
        guard let range = objective.range(of: "\n\n確認済みの点:\n") else { return objective }
        return String(objective[..<range.lowerBound])
    }

    /// The package's own Swift sources (not tests, not build output), largest budget first come first, for the prompt.
    public static func sources(in root: URL, limitBytes: Int = 48_000) -> [(path: String, content: String)] {
        let sourcesFolder = root.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sourcesFolder, includingPropertiesForKeys: nil) else { return [] }
        var files: [(path: String, content: String)] = []
        var total = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard total + content.utf8.count <= limitBytes else { continue }
            total += content.utf8.count
            files.append((String(url.path.dropFirst(root.path.count + 1)), content))
        }
        return files.sorted { $0.path < $1.path }
    }
}
