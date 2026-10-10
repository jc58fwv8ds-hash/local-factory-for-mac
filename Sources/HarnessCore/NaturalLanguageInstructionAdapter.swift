import Foundation

public struct NaturalLanguageAdaptation: Equatable, Sendable {
    public let interpretation: String
    public let responseGuidance: String
    public let usesCasualJapanese: Bool

    public init(
        interpretation: String,
        responseGuidance: String,
        usesCasualJapanese: Bool
    ) {
        self.interpretation = interpretation
        self.responseGuidance = responseGuidance
        self.usesCasualJapanese = usesCasualJapanese
    }
}

public enum NaturalLanguageInstructionAdapter {
    public static func adapt(for project: HarnessProject) -> NaturalLanguageAdaptation {
        let userMessages = ProjectInstructionContext.userMessages(in: project)
        let latest = userMessages.last?.content.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        let casual = ContinuationInstruction.matches(latest)
            || prefersCasualJapanese(userMessages.suffix(8).map(\.content))
        return NaturalLanguageAdaptation(
            interpretation: ProjectInstructionContext.interpretation(for: project),
            responseGuidance: responseGuidance(casual: casual),
            usesCasualJapanese: casual
        )
    }

    public static func responseGuidance(for instruction: String) -> String {
        let cleaned = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return responseGuidance(
            casual: ContinuationInstruction.matches(cleaned)
                || prefersCasualJapanese([cleaned])
        )
    }

    private static func prefersCasualJapanese(_ messages: [String]) -> Bool {
        var score = 0
        for text in messages {
            if text.contains("〜") || text.contains("～") { score += 2 }
            if text.contains("ね") || text.contains("よ") { score += 1 }
            if text.contains("続けよう") || text.contains("進めよう") { score += 2 }
            if text.contains("してね") || text.contains("ちょ") { score += 2 }
            if text.contains("してください") || text.contains("お願いします") { score -= 1 }
        }
        return score >= 2
    }

    private static func responseGuidance(casual: Bool) -> String {
        let tone = casual
            ? "丁寧すぎない、落ち着いた親しみのある日本語にします。『〜だね』『〜しよう』は自然な範囲で使い、無理に俗語を真似しません。"
            : "読みやすい標準的な日本語にします。"
        return """
        \(tone)
        最初に結論か現在の結果を伝え、短い段落で答えてください。
        かしこまった前置きや長い見出しを避け、指定された文数・短さを守ってください。
        不要なAI用語、内部プロンプト、JSON、英語の見出しは見せないでください。
        \(NaturalLanguageExplanationGuidance.instructions)
        Qwen、Xcode、SwiftUIなど必要な固有名詞は変えないでください。
        """
    }
}
