import Foundation

/// Clothing the user asked to be gone, taken out of the written prompt (2026-11-10, the user: 「既存のチャット欄でも未だ指示に
/// 従わないみたい」). The writer kept the shirt it saw in the picture: 「She is nude except for a white shirt draped over her left
/// shoulder」, and after 「ワイシャツを全て削除。全裸にして」 it only added 「Her clothes are removed.」, so the shirt was drawn
/// again. This does not rely on the writer: the clauses that name the clothing go, and the state is said plainly.
public enum Undress {
    /// Garments by the Japanese words for them, with the English words a prompt uses.
    static let garments: [(japanese: [String], english: [String])] = [
        (["ワイシャツ", "シャツ", "Yシャツ"], ["shirt", "shirts"]),
        (["ブラウス"], ["blouse"]),
        (["着物"], ["kimono"]),
        (["浴衣"], ["yukata"]),
        (["下着"], ["underwear", "lingerie", "bra", "panties", "knickers"]),
        (["ブラ"], ["bra"]),
        (["ショーツ", "パンツ", "パンティ"], ["panties", "knickers"]),
        (["スカート"], ["skirt"]),
        (["ジーンズ", "ズボン"], ["jeans", "trousers", "pants"]),
        (["ワンピース", "ドレス"], ["dress", "gown"]),
        (["セーター", "ニット"], ["sweater", "knit"]),
        (["カーディガン"], ["cardigan"]),
        (["ジャケット", "上着", "コート"], ["jacket", "coat"]),
        (["ガウン", "バスローブ", "ローブ"], ["robe", "gown", "bathrobe"]),
        (["ストッキング", "タイツ"], ["stockings", "tights", "pantyhose"]),
        (["靴下", "ソックス"], ["socks"]),
    ]
    // Not 「top」, 「suit」 or 「towel」: 「on top of the bed」 is not clothing.
    static let anyGarment = ["clothes", "clothing", "garment", "garments", "outfit", "t-shirt", "tank top", "nightgown", "negligee",
                             "pajamas", "uniform", "sash", "obi"] + garments.flatMap(\.english)

    /// The English garment words to take out: every garment when the request is for nakedness, the named ones when it asks
    /// for them to be removed, none otherwise. For a video, 「脱がせて」 is the undressing itself, so it does not count.
    public static func removed(in instruction: String, isVideo: Bool = false) -> [String] {
        let naked = ["全裸", "裸に", "裸で", "裸の", "すっぽんぽん", "一糸まとわ", "何も着て", "何も身に着け", "全部脱いだ", "全て脱いだ", "すべて脱いだ"]
        let take = ["削除", "消して", "消す", "無くし", "なくし", "取り除", "取って", "外して", "なしに", "無しに"] + (isVideo ? [] : ["脱が", "脱い", "脱ぐ"])
        if naked.contains(where: instruction.contains) { return anyGarment }
        guard take.contains(where: instruction.contains) else { return [] }
        if ["服", "衣服", "衣装"].contains(where: instruction.contains) && !isVideo { return anyGarment }
        return garments.filter { $0.japanese.contains(where: instruction.contains) }.flatMap(\.english)
    }

    /// The prompt with the clauses that name the removed clothing taken out, and the state said once at the end.
    public static func apply(_ prompt: String, instruction: String, isVideo: Bool = false) -> String {
        let words = removed(in: instruction, isVideo: isVideo)
        guard !words.isEmpty else { return prompt }
        let pattern = "(?i)\\b(" + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\b"
        guard let garment = try? NSRegularExpression(pattern: pattern) else { return prompt }
        func names(_ text: String) -> Bool { garment.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        var sentences: [String] = []
        for sentence in prompt.components(separatedBy: CharacterSet(charactersIn: ".!?")) {
            var text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // 「nude except for a white shirt draped over her shoulder」 -> 「nude」.
            text = text.replacingOccurrences(of: "(?i)\\s*(,\\s*)?(except|apart|save) (for|from) [^,]*", with: "", options: .regularExpression)
            let clauses = text.components(separatedBy: ", ").filter { !names($0) }
            text = clauses.joined(separator: ", ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { sentences.append(text) }
        }
        let everything = words.count == anyGarment.count
        let state = everything
            ? "She is completely naked and wears nothing at all: no shirt, no cloth on her shoulders, arms or lap, no underwear."
            : "She no longer wears the " + Array(Set(words.prefix(2))).sorted().joined(separator: " or ") + "; it is gone completely."
        return (sentences.map { $0 + "." } + [state]).joined(separator: " ")
    }
}
