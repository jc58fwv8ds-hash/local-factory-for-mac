import Foundation
import HarnessCore

/// A short code-chat message that points back at what came before — 「その案で作って」「それでお願い」「今の方向で進めて」 —
/// planned together with the request and the answer it points at (2026-11-16: 「その案で作って」 was planned from those
/// words alone, and the files were rewritten for a purpose nobody had asked for).
enum CodeChatFollowUp {
    static let maximumAnswerCharacters = 3_000
    static let maximumRequestCharacters = 3_000

    static func pointsBack(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count <= 60 else { return false }
        return cleaned.range(of: #"(その|この|今の|さっきの|前の|上の|いまの)(案|方向|方針|内容|計画|設計|通り|とおり|形|やり方)"#,
                             options: .regularExpression) != nil
            || cleaned.range(of: #"^(それ|これ|それら|そちら)(で|を|に)"#, options: .regularExpression) != nil
    }

    /// The text to plan from, or nil when the message stands on its own.
    static func request(_ text: String, conversation: [ConversationMessage]) -> String? {
        guard pointsBack(text) else { return nil }
        // The last thing the user asked for, and what was answered after it.
        // An earlier 「その案で作って」 is skipped: it points at the same request (2026-11-16: sent again after a stopped run).
        guard let askedIndex = conversation.lastIndex(where: {
            $0.role == .user && $0.origin == .user && !pointsBack($0.content)
        }) else { return nil }
        let asked = conversation[askedIndex].content.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = conversation[(askedIndex + 1)...]
            .filter { $0.role == .assistant }
            .map(\.content)
            .max { $0.count < $1.count }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !asked.isEmpty || !answer.isEmpty else { return nil }
        var parts = [text]
        if !asked.isEmpty {
            parts.append("この言葉が指している、前の依頼(ユーザーが書いたもの。具体的な値・一覧はこのとおりに使う):\n"
                + String(asked.prefix(maximumRequestCharacters)))
        }
        if !answer.isEmpty {
            parts.append("その依頼への案(Factory が返したもの。ユーザーが良いと言ったのはこの案):\n"
                + String(answer.prefix(maximumAnswerCharacters)))
        }
        return parts.joined(separator: "\n\n")
    }
}
