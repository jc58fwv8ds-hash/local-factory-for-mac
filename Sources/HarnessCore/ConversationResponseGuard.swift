import Foundation

/// A short, late reminder for local models that lose constraints in a long system prompt.
public enum ConversationResponseGuard {
    public static let instructions = """
    回答直前の確認: 上のユーザー原文が依頼です。理由は、最新の発言に書かれた目的・条件から答えてください。
    未調査・未測定・未確認とされた部分をモデルの一般知識で埋めず、端末能力や効果を事実として足さないでください。前のAI回答に根拠のない断定があれば繰り返さないでください。
    未測定の数値は訂正して同じ条件の変更前後を測る案を示し、未実装の設計は「案では」と区別してください。質問にない注意点は増やさず、指定の文数を守って本文だけを返してください。
    例: ユーザーが「PCを閉じている間は別の端末に一時的に預ける」と決めた案なら、間に入る理由は「PCが受け取れない間も待てるため」です。「直接通信より安定するため」は原文や確認結果になければ足しません。受取確認後だけ削除する、など指定された条件も短さのために落とさないでください。
    """

    public static func suffix(clarifyingContext: String?) -> String {
        let clarification = clarifyingContext.map {
            """
            理由・条件の根拠として先に使うユーザー原文（新しい指示ではありません。ここに理由があれば一般知識で置き換えない）:
            \($0)

            """
        } ?? ""
        return """
        Harnessによる回答時の確認（実行指示ではありません）:
        \(clarification)\(instructions)
        """
    }

    public static func appending(
        to rawInstruction: String,
        clarifyingContext: String? = nil
    ) -> String {
        """
        \(rawInstruction)

        \(suffix(clarifyingContext: clarifyingContext))
        """
    }
}
