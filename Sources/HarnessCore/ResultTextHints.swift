import Foundation

/// Text taken from the wrong place, found on the iPhone on 2026-11-18 once 14Translate stopped crashing: the screen showed
/// only 「演説」, because the listener sent `result.description` — the debug dump 「<Speech.SpeechTranscriber.Result: range …」
/// — to translation instead of the words heard; and every glossary term failed with 「"\b\(escapedTerm)\b" が無効」, because
/// `"\\b\\(escapedTerm)\\b"` writes a backslash and `(escapedTerm)` instead of putting the term in.
extension NotWorkingHints {
    static let debugTextMark = "結果のデバッグ用の文字"
    static let escapedInterpolationMark = "埋め込みのつもりの"

    public static func wrongText(_ texts: [(String, String)]) -> [String] {
        var hints: [String] = []
        for (path, text) in texts {
            let lines = text.components(separatedBy: "\n")
            if text.contains("SpeechTranscriber") || text.contains("SpeechAnalyzer") || text.contains("DictationTranscriber"),
               let index = lines.firstIndex(where: { $0.range(of: #"\b(result|transcription|res|r)\.description\b"#, options: .regularExpression) != nil }) {
                hints.append("\(path) の \(index + 1) 行目「\(lines[index].trimmingCharacters(in: .whitespaces).prefix(60))」は、聞き取り結果の \(debugTextMark)(description。"
                    + "「<Speech.SpeechTranscriber.Result: range …」のような中身の説明)を、聞き取った言葉として使っています。"
                    + "これを訳すと「演説」などの意味のない訳になります。聞き取った言葉は String(result.text.characters) で取り出してください。")
            }
            if let index = lines.firstIndex(where: { $0.range(of: #""[^"\n]*\\\\\([A-Za-z_][A-Za-z0-9_.]*\)[^"\n]*""#, options: .regularExpression) != nil }) {
                hints.append("\(path) の \(index + 1) 行目「\(lines[index].trimmingCharacters(in: .whitespaces).prefix(70))」は、\(escapedInterpolationMark) \\\\( が、"
                    + "バックスラッシュと「(名前)」という文字そのものになっています。値は入らず、正規表現なら毎回エラーになります。"
                    + "値を入れるなら \\(名前) と書き、\\b などの記号は \"\\\\b\" + 名前 + \"\\\\b\" のように分けて足してください。")
            }
        }
        return hints
    }
}
