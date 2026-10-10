import Foundation

/// Enforces only an explicit, exact sentence count from the latest real user message.
public struct ConversationSentenceCountPolicy: Equatable, Sendable {
    public let expectedCount: Int

    public init?(project: HarnessProject) {
        guard let instruction = ProjectInstructionContext.userMessages(in: project).last?.content else {
            return nil
        }
        self.init(instruction: instruction)
    }

    public init?(instruction: String) {
        guard !Self.containsRange(instruction),
              let token = Self.lastMatch(in: instruction),
              let count = Self.number(for: token), (1...10).contains(count) else {
            return nil
        }
        expectedCount = count
    }

    public func validationError(for response: String) -> InferenceError? {
        let actual = Self.sentenceCount(in: response)
        guard actual > 0, actual != expectedCount else { return nil }
        return .responseSentenceCount(expected: expectedCount, actual: actual)
    }

    public func refinementRequest(
        from request: InferenceRequest,
        response: String
    ) -> InferenceRequest {
        let actual = Self.sentenceCount(in: response)
        let draft = PromptReferenceText.excerpt(
            ConversationResponseText.visibleText(response), maximumCharacters: 2_000
        )
        return InferenceRequest(
            runtime: request.runtime,
            modelIdentifier: request.modelIdentifier,
            messages: request.messages + [
                InferenceMessage(role: .assistant, content: draft),
                InferenceMessage(role: .user, content: """
                    Harnessの返答検査で、ユーザーは本文をちょうど\(expectedCount)文と指定しましたが、直前の案は\(actual)文でした。まだ保存していません。
                    直前の案の意味と、未調査・未確認の区別を保ったまま、本文だけをちょうど\(expectedCount)文にまとめ直してください。
                    新しい事実、見出し、箇条書き、前置きは足さないでください。
                    これは新しい制作指示や実行の承認ではありません。
                    """)
            ],
            maximumOutputTokens: request.maximumOutputTokens,
            structuredOutput: request.structuredOutput,
            images: request.images
        )
    }

    public static func sentenceCount(in response: String) -> Int {
        let visible = ConversationResponseText.visibleText(response)
        let boundaries = CharacterSet(charactersIn: "。！？!?\n\r")
        return visible.components(separatedBy: boundaries).count {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static let exactPattern = try! NSRegularExpression(
        pattern: #"(?<![0-9一二三四五六七八九十])(10|[1-9]|一|二|三|四|五|六|七|八|九|十)\s*文(?:で(?!は?なく)|に(?!しな)|だけ(?!はやめ|で?なく))"#
    )
    private static let rangePattern = try! NSRegularExpression(
        pattern: #"(?:10|[1-9]|一|二|三|四|五|六|七|八|九|十)\s*[〜~～\-－–—]\s*(?:10|[1-9]|一|二|三|四|五|六|七|八|九|十)\s*文"#
    )

    private static func containsRange(_ text: String) -> Bool {
        rangePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func lastMatch(in text: String) -> String? {
        guard let match = exactPattern.matches(
            in: text, range: NSRange(text.startIndex..., in: text)
        ).last, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func number(for token: String) -> Int? {
        Int(token) ?? [
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9, "十": 10
        ][token]
    }
}
