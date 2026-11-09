import Foundation

/// What a video says, chosen beside the input when 「動画を作る」 is chosen (2026-11-10, the user: 「音声を添付の有無とセリフ設定
/// の有無を選べると良いね。セリフは複数人分を読み込んでも分けて音声でつくと良いかな」).
public enum VideoSpeech: String, CaseIterable, Sendable {
    /// Lines when the request asks for them, written by the prompt writer (as before).
    case auto
    /// No lines: the video's own sounds only.
    case none
    /// The lines the user wrote, one voice per speaker.
    case script

    /// Where the choice and the lines are kept between runs (UserDefaults).
    public static let settingKey = "videoSpeech"
    public static let scriptKey = "videoScript"

    public var title: String {
        switch self {
        case .auto: "セリフ: おまかせ"
        case .none: "セリフなし"
        case .script: "セリフを入力"
        }
    }
}

/// Lines written as 「名前: セリフ」 (or 「名前「セリフ」」), one per line; each speaker gets a voice of their own.
public enum VideoScript {
    public struct Line: Equatable, Sendable {
        public var speaker: String
        public var text: String
        public init(speaker: String, text: String) { self.speaker = speaker; self.text = text }
    }

    /// The lines in order. A line without a name is said by the one before it (or by 「」 when none came before).
    public static func parse(_ script: String) -> [Line] {
        var lines: [Line] = []
        for raw in script.split(whereSeparator: \.isNewline) {
            let row = raw.trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty else { continue }
            if let (name, text) = named(row) {
                lines.append(Line(speaker: name, text: text))
            } else {
                lines.append(Line(speaker: lines.last?.speaker ?? "", text: unquoted(row)))
            }
        }
        return lines.filter { !$0.text.isEmpty }
    }

    /// The speakers in the order they first speak.
    public static func speakers(_ lines: [Line]) -> [String] {
        lines.reduce(into: [String]()) { if !$0.contains($1.speaker) { $0.append($1.speaker) } }
    }

    /// The voice for a speaker, described for the voice model: a man's voice for a name that says so, otherwise a woman's;
    /// a second woman or man sounds different from the first.
    public static func caption(for speaker: String, among speakers: [String]) -> String {
        let male = isMale(speaker)
        let same = speakers.filter { isMale($0) == male }
        let turn = same.firstIndex(of: speaker) ?? 0
        let men = ["落ち着いた低い声の大人の男性", "少しかすれた、穏やかな大人の男性の声", "明るくはっきりした大人の男性の声"]
        let women = ["落ち着いた、近い距離感の大人の女性の声", "少し高めの、柔らかい大人の女性の声", "低めで艶のある大人の女性の声"]
        let voices = male ? men : women
        return voices[turn % voices.count]
    }

    /// A seed of its own for each speaker, so one speaker keeps one voice through the lines.
    public static func seed(_ base: Int, speaker: String, among speakers: [String]) -> Int {
        base + 101 * ((speakers.firstIndex(of: speaker) ?? 0) + 1)
    }

    static func isMale(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["男", "彼氏", "夫", "旦那", "俺", "僕", "父", "兄", "弟", "おじ"].contains(where: name.contains)
            || ["man", "male", "boy", "husband", "he"].contains(lower)
    }

    private static func named(_ row: String) -> (String, String)? {
        for mark in [":", "：", "「"] {
            guard let range = row.range(of: mark) else { continue }
            let name = row[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            // A name is short and has no sentence in it; 「あっ…んっ」 has no name.
            guard !name.isEmpty, name.count <= 12, !name.contains("。"), !name.contains("、") else { continue }
            let text = mark == "「" ? String(row[range.lowerBound...]) : String(row[range.upperBound...])
            return (name, unquoted(text))
        }
        return nil
    }

    private static func unquoted(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("「"), t.hasSuffix("」") { t = String(t.dropFirst().dropLast()) }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
