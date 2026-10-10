import Foundation

public enum PrimaryInstructionRoute: Equatable, Sendable {
    case modelConversation
    case computerOperation
}

public enum PrimaryInstructionIntentRouter {
    public static func route(_ instruction: String) -> PrimaryInstructionRoute {
        let normalized = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        guard !normalized.isEmpty else { return .modelConversation }

        let productionActions = [
            "修正して", "直して", "作って", "追加して", "変更して",
            "実装して", "生成して", "書き換えて"
        ]
        guard !productionActions.contains(where: normalized.contains) else {
            return .modelConversation
        }

        let japaneseActions = [
            "ビルドして", "buildして", "テストして", "testして",
            "検証して", "検索して", "調べて", "画面を読み取って",
            "画面を確認して", "ボタンを押して", "クリックして"
        ]
        if japaneseActions.contains(where: normalized.contains) {
            return .computerOperation
        }

        let english = instruction.lowercased()
        let englishActions = [
            "build the project", "run the tests", "run tests",
            "search for", "search the web", "inspect the app",
            "inspect the screen", "press the button", "click the button"
        ]
        return englishActions.contains(where: english.contains)
            ? .computerOperation
            : .modelConversation
    }

    /// Words that ask to change the code of the connected project (used only when a Swift package is connected).
    public static func isCodeChangeRequest(_ instruction: String) -> Bool {
        let normalized = instruction.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
        let verbs = ["直して", "修正して", "変更して", "追加して", "書き換えて", "削除して", "消して", "にして", "変えて",
                     "fix ", "change ", "add "]
        return verbs.contains(where: normalized.contains) || ["fix ", "change ", "add "].contains(where: instruction.lowercased().contains)
    }

    /// A request-like sentence the keywords did not classify (for the system-model check): not a question, and ends like
    /// a request or a wish.
    public static func mayBeChangeRequest(_ instruction: String) -> Bool {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasSuffix("?"), !text.hasSuffix("？"),
              !["教えて", "説明して", "とは", "どう思う", "なぜ", "どうして"].contains(where: text.contains) else { return false }
        return ["して", "てほしい", "て欲しい", "ようにしたい", "ようにして", "したい", "ください", "たい"].contains(where: text.hasSuffix)
            || ["ようにして", "してほしい"].contains(where: text.contains)
    }
}
