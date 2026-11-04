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

    /// The words only the minors line uses (a sexual word alone blocks nothing). 2026-11-04, the user: every word must be
    /// the user's to edit, so the app can be changed without Claude. Two parts:
    /// - `core…`: the floor the line needs (explicit sexual words, unmistakable minor words); fixed, because removing them
    ///   would switch the line off.
    /// - `default…`: everything else; the user removes or restores each one in the settings, and adds their own.
    public static let coreSexualWords = [
        "性的", "セックス", "性行為", "性交", "性器", "ポルノ", "裸", "ヌード", "全裸", "わいせつ", "猥褻",
        "sex", "sexual", "nude", "naked", "porn", "erotic", "explicit", "hentai",
    ]
    public static let defaultSexualWords = [
        "エロ", "えっち", "エッチ", "半裸", "下着姿", "卑猥", "官能", "アダルト", "成人向け", "18禁", "R18", "R-18", "淫",
        "乳首", "愛撫", "nsfw", "lewd",
    ]
    public static let coreMinorWords = [
        "未成年", "18歳未満", "十八歳未満", "小学生", "中学生", "児童", "幼児", "幼女", "園児", "赤ちゃん", "子ども", "子供", "こども",
        "ロリ", "ショタ", "child", "children", "minor", "underage", "kid", "kids", "toddler", "preteen", "loli", "shota",
    ]
    public static let defaultMinorWords = [
        "高校生", "女子高生", "男子高生", "幼い子", "JS", "JC", "JK", "teenager", "schoolgirl",
    ]
    /// Every word the app ships with (for the exception rule and the settings screen).
    public static var sexualWords: [String] { coreSexualWords + defaultSexualWords }
    public static var minorWords: [String] { coreMinorWords + defaultMinorWords }

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

    /// `exceptions`: phrases the user registered after a false detection (2026-11-02, settings screen); they are not
    /// counted, like `neutralPhrases`. An age under 18 written out still blocks, whatever is registered.
    /// `sexualWords` / `minorWords`: the user's editable words (the defaults minus the removed ones, plus the added ones);
    /// the core words are always counted on top.
    public static func check(_ instruction: String, attachesPhoto: Bool = false, exceptions: [String] = [],
                             sexualWords editableSexual: [String] = defaultSexualWords,
                             minorWords editableMinor: [String] = defaultMinorWords) -> Decision {
        let instruction = neutralPhrases.reduce(instruction) { $0.replacingOccurrences(of: $1, with: "・") }
        let words = exceptions.filter { exceptionProblem($0) == nil }.reduce(instruction) { $0.replacingOccurrences(of: $1, with: "・") }
        let sexual = contains(words, any: coreSexualWords + editableSexual)
        guard let sexualWord = sexual else { return .allow }
        if let minor = contains(words, any: coreMinorWords + editableMinor) ?? statedMinorAge(in: instruction) {
            return .block(reason: "「\(minor)」と「\(sexualWord)」が同じ指示にあるため作りません(未成年を性的に描く内容は扱いません)。")
        }
        if attachesPhoto {
            return .confirmConsent(reason: "読み込んだ写真を性的な内容に作り替える指示です。写真の人物が実在する場合、本人の同意がありますか？")
        }
        return .allow
    }

    /// Why a phrase cannot be registered, or nil. A phrase must say more than a listed word alone: registering 「小学生」 or
    /// 「エロ」 would switch a line off, while 「小学生の頃の思い出」 only stops one everyday phrase from counting.
    public static func exceptionProblem(_ phrase: String) -> String? {
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return "3 文字以上の言い回しにしてください" }
        if statedMinorAge(in: text) != nil { return "18 歳未満の年齢を含む言い回しは登録できません" }
        for word in coreSexualWords + coreMinorWords where text.localizedCaseInsensitiveContains(word) {
            if text.count < word.count + 3 { return "「\(word)」だけに近い言い回しは登録できません(前後の言葉も含めてください)" }
        }
        return nil
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
