import Foundation

/// Spots code left half-done: a stand-in screen, a "put it here later" comment, a call left commented out, or a
/// function that only says it is not supported (2026-11-16: 14Translate's glossary editor was an empty stand-in, the
/// language switch only printed "does not support", and the run still reported 「できました」).
public enum UnfinishedCode {
    private static let commentWords = [
        "プレースホルダ", "placeholder", "todo", "fixme", "ここに", "後で実装", "あとで実装", "未実装",
        "ロジックがあれば", "not implemented", "implement later", "仮の", "仮実装", "stub"
    ]
    private static let anywhereWords = [
        "does not support", "not supported", "not yet supported", "未対応のため", "対応していないため",
        "警告のみ"
    ]
    private static let commentedCall = try! NSRegularExpression(
        pattern: #"^//+\s*(?:self\.)?[A-Za-z_][\w.]*\([^)]*\)\s*;?\s*$"#
    )

    /// Lines of `content` that look unfinished and were not already in `previous` (an old file's own notes are left
    /// alone; only what this change brings in counts).
    public static func findings(in content: String, previous: String? = nil) -> [String] {
        let old = Set((previous ?? "").components(separatedBy: .newlines).map(trimmed))
        var found: [String] = []
        let lines = content.components(separatedBy: .newlines).map(trimmed)
        for (index, line) in lines.enumerated() {
            let next = lines[(index + 1)...].first { !$0.isEmpty } ?? ""
            guard !line.isEmpty, !old.contains(line), isUnfinished(line, next: next) else { continue }
            if !found.contains(line) { found.append(line) }
            if found.count == 8 { break }
        }
        return found
    }

    /// What to tell the writer when unfinished lines were found.
    public static func feedback(_ findings: [String]) -> String {
        """
        書いた内容に、まだ動かない仮の作りが残っています:
        \(findings.map { "- \($0)" }.joined(separator: "\n"))
        仮の画面・「ここに追加」・コメントにした呼び出し・「対応していない」とだけ言う処理を残さず、頼まれたことが実際に動く形で、ファイルの全文を書き直してください。必要な関数がほかのファイルにないなら、このファイルの中で実際に動く形で用意してください。
        """
    }

    /// `next` is the next non-empty line. 「Not supported」 counts only in code that says so and then ends, not in a comment
    /// about a real check (2026-11-17: 「// If the current locale is not supported, fall back to …」 above working code was
    /// called a stand-in four times and the run stopped).
    static func isUnfinished(_ line: String, next: String = "}") -> Bool {
        let lower = line.lowercased()
        let isComment = line.hasPrefix("//") || line.hasPrefix("/*") || line.hasPrefix("*")
        if !isComment, anywhereWords.contains(where: { lower.contains($0) }),
           next.hasPrefix("}") || next.hasPrefix("return") { return true }
        guard let comment = commentText(of: line) else { return false }
        let commentLower = comment.lowercased()
        if commentWords.contains(where: { commentLower.contains($0) }) { return true }
        let range = NSRange(line.startIndex..., in: line)
        return commentedCall.firstMatch(in: line, range: range) != nil
    }

    private static func commentText(of line: String) -> String? {
        if line.hasPrefix("//") || line.hasPrefix("/*") || line.hasPrefix("*") || line.hasPrefix("#") {
            return line
        }
        guard let range = line.range(of: " //") else { return nil }
        return String(line[range.upperBound...])
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }
}
