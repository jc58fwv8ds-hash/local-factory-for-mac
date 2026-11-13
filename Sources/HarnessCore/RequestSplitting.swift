import Foundation

/// A message with several things to fix, split into requests that can each be built and checked on its own
/// (2026-11-12: the user sent five points about 14Translate in one message with three screenshots).
public enum RequestSplitting {
    /// Worth asking a model to split: more than one sentence or item, or a long message.
    public static func mayHoldSeveral(_ text: String) -> Bool {
        let marks = text.filter { "。・\n？?！!".contains($0) }.count
        return marks >= 2 || text.count > 120
    }

    public static func prompt(_ text: String, pictures: String?) -> String {
        """
        アプリを作っている利用者から、次のメッセージが届きました。直してほしいことや足してほしいことを、別々に作業できる依頼に分けてください。

        決まり:
        - 依頼ごとに、利用者の言葉をできるだけそのまま使い、何をどうしてほしいかが一つで伝わる文にする。
        - 画面写真のことを言っている依頼には、どの写真か(画像1 など)を書き添える。
        - 「〜は健在」「〜のまま」「まだ〜」のように、まだ直っていないことを伝える文は、それを直す依頼にする(言葉を省かない。例:「二頭を『にあたま』と読む読み上げミスを直す」)。
        - 「〜は嬉しかった」のような感想・お礼・質問だけの文は依頼にしない。
        - 状況の説明(「起動する前から英語を流していた」「iPhone だけで試した」)や、原因の推測(「メモリリークしているのか」「遅いのか」)は依頼にしない。
          それは、その不具合の依頼の文にそのまま書き添える(例:「起動前から英語を流していたのに、一瞬訳してすぐ止まる不具合を直す(原因は遅さかメモリリークかと利用者は推測)」)。
        - 一つの不具合を、症状・状況・推測に分けて何件にもしない。分けるのは、別々に直せる別の問題のときだけ。
        - 同じことを言っている文は一つにまとめる。
        - 順番は、動かない・止まる・エラーなどの不具合を先に、見た目や新しい機能を後にする。
        - 答えは JSON の文字列の配列だけ。例: ["…を直す", "…を足す"]

        メッセージ:
        \(text)
        \(pictures.map { "\n画面写真について読み取ったこと:\n" + $0.prefix(3000) } ?? "")
        """
    }

    /// The requests from the model's answer: a JSON array of strings, also inside a code block. Nil when there is none.
    public static func parse(_ answer: String) -> [String]? {
        guard let start = answer.firstIndex(of: "["), let end = answer.lastIndex(of: "]"), start < end,
              let data = String(answer[start...end]).data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let requests = items.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return requests.isEmpty ? nil : Array(requests.prefix(8))
    }

    /// Only what the person asked: an item made of what was read from the pictures, or longer than the whole message, is not
    /// one of their requests (2026-11-12: the description of a screenshot came back as request 2 of 2).
    public static func ownAsks(_ items: [String], in text: String) -> [String] {
        let kept = items.filter { item in
            !item.hasPrefix("画面写真") && !item.hasPrefix("画像") && !item.contains("読み取ったこと") && item.count <= text.count + 80
        }
        return kept.isEmpty ? [text] : kept
    }
}

