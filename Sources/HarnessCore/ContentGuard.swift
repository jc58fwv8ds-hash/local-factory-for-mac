import Foundation

/// The two lines the app never crosses in writing and image generation (2026-10-09), decided from the words of the
/// instruction only — no model judges the "mood" of a request, so ordinary creative work is not caught by guesswork.
/// 1. Sexual content involving minors: blocked only when the same instruction has a sexual word AND a word that states a
///    minor (an age under 18, 小学生, 中学生, 児童, 子ども …). Art style, uniforms, an anime look or an unstated age are not
///    signals. 2. A sexual remake of an attached real photo: not blocked; the user confirms consent once.
/// Measured on 200 ordinary creative instructions before use (Tests: ContentGuardTests).
public enum ContentGuard {
    public enum Decision: Equatable, Sendable {
        case allow
        case block(reason: String)
        case confirmConsent(reason: String)
    }

    static let sexualWords = [
        "性的", "エロ", "えっち", "エッチ", "セックス", "性行為", "性交", "裸", "ヌード", "全裸", "半裸", "下着姿", "卑猥", "官能",
        "ポルノ", "アダルト", "成人向け", "18禁", "R18", "R-18", "淫", "わいせつ", "猥褻", "乳首", "性器", "愛撫",
        "sex", "sexual", "nude", "naked", "porn", "nsfw", "erotic", "explicit", "lewd", "hentai",
    ]
    static let minorWords = [
        "未成年", "18歳未満", "十八歳未満", "小学生", "中学生", "高校生", "女子高生", "男子高生", "児童", "幼児", "幼女", "幼い子",
        "子ども", "子供", "こども", "園児", "赤ちゃん", "JS", "JC", "JK", "ロリ", "ショタ",
        "child", "children", "minor", "underage", "kid", "kids", "toddler", "preteen", "teenager", "schoolgirl", "loli", "shota",
    ]

    /// Everyday compounds that contain a listed word but mean something else (裸足 = barefoot, 子ども向け = for children as an
    /// audience, 子どもの頃 = in one's childhood); they are removed before matching.
    static let neutralPhrases = [
        "裸足", "赤裸々", "裸電球", "裸眼", "裸一貫", "裸の王様",
        "子ども向け", "子供向け", "こども向け", "子どもの頃", "子供の頃", "こどもの頃", "子供時代", "子ども時代", "幼い頃",
        "子育て", "子供連れ", "子ども連れ", "子供用", "子ども用", "子供服", "子ども服",
        // Saying there is no sexual content is not a sexual word (いじめを乗り越える中学生の物語(性的な描写なし)).
        "性的な描写なし", "性的な描写はなし", "性的な描写は無し", "性的な表現なし", "性的な内容なし", "性的な要素なし", "性的でない",
        "non-sexual", "no sexual content",
    ]

    public static func check(_ instruction: String, attachesPhoto: Bool = false) -> Decision {
        let instruction = neutralPhrases.reduce(instruction) { $0.replacingOccurrences(of: $1, with: "・") }
        let sexual = contains(instruction, any: sexualWords)
        guard let sexualWord = sexual else { return .allow }
        if let minor = contains(instruction, any: minorWords) ?? statedMinorAge(in: instruction) {
            return .block(reason: "「\(minor)」と「\(sexualWord)」が同じ指示にあるため作りません(未成年を性的に描く内容は扱いません)。")
        }
        if attachesPhoto {
            return .confirmConsent(reason: "読み込んだ写真を性的な内容に作り替える指示です。写真の人物が実在する場合、本人の同意がありますか？")
        }
        return .allow
    }

    /// The first word found; ASCII words match whole words only ("kid" is not found in "kidney", "JS" not in "JSON").
    static func contains(_ text: String, any words: [String]) -> String? {
        let lowered = text.lowercased()
        for word in words {
            let needle = word.lowercased()
            if needle.allSatisfy({ $0.isASCII }) {
                let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: needle) + "(?![A-Za-z0-9])"
                if lowered.range(of: pattern, options: .regularExpression) != nil { return word }
            } else if lowered.contains(needle) {
                return word
            }
        }
        return nil
    }

    /// "12歳", "15才", "17 years old", "age 16": an age under 18 written out.
    static func statedMinorAge(in text: String) -> String? {
        let patterns = [#"(?<![0-9])([0-9]{1,2})\s*(歳|才|さい)"#, #"(?<![0-9])([0-9]{1,2})\s*(-|\s)?years?(-|\s)?old"#,
                        #"age\s*([0-9]{1,2})(?![0-9])"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text), let age = Int(text[range]), age < 18,
                      let whole = Range(match.range, in: text) else { continue }
                return String(text[whole])
            }
        }
        return nil
    }
}
