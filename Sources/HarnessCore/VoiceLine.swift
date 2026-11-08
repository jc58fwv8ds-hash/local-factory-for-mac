import Foundation

/// A Japanese voice laid over a finished video (2026-11-08): the video model makes sounds with the picture but no clear
/// Japanese voice or lines. The prompt writer writes what she says and how her voice sounds; a voice model reads it in a
/// voice made from that description only, never from a real person's recording.
public enum VoiceLine {
    /// The request asks for a voice, lines or vocal sounds.
    public static func wanted(_ instruction: String) -> Bool {
        ["声", "セリフ", "台詞", "喘", "囁", "ささや", "音声", "しゃべ", "喋", "話して", "言って", "言わせ", "「"].contains(where: instruction.contains)
    }

    /// What the prompt writer is asked: the spoken words with the voice model's emoji, and a description of the voice.
    public static func writerRequest(instruction: String, videoPrompt: String) -> String {
        """
        A video was made from this request:
        \(instruction)

        The video shows:
        \(videoPrompt)

        Write what she herself says or voices during the video, in Japanese, at most 60 characters, as the request asks (keep any words the user put in 「」 exactly). These are her own sounds and words, never the request itself: for moaning, for example 「🥵あっ…んっ…🌬はぁ…はぁ…🥵」. Put these marks where the delivery changes: 🥵 panting or moaning, 🌬 heavy breathing, 😮‍💨 a sigh, 👂 a whisper close to the ear, ⏸ a short pause; twice the same mark makes it stronger. Use ひらがな for hard kanji.
        Then describe her voice in Japanese in one short sentence (age, tone, how close it sounds), for an adult woman unless the request says otherwise.
        Answer in exactly two lines and nothing else:
        TEXT: <the words>
        CAPTION: <the voice>
        """
    }

    /// Moaning, when the writer's words are not usable for a request that asks for it.
    public static let moaning = "🥵あっ…んっ…🌬はぁ…はぁ…🥵んんっ…あぁっ…🥵🥵"

    /// The words to read: the writer's, unless they repeat the request (2026-11-08: the voice read out
    /// 「自慰を続けさせて喘ぎ声も入れて」), in which case moaning when moaning was asked for, else nothing.
    public static func words(_ text: String, instruction: String) -> String? {
        // The user's own lines in 「」 are meant to be read; only the rest of the request must not be (2026-11-08:
        // 「ねえ、こっちを見て。」 was taken for the request read out, and the video got no voice).
        let instruction = instruction.replacingOccurrences(of: "「[^」]*」", with: "", options: .regularExpression)
        let plain = text.filter { !$0.isPunctuation && !$0.isWhitespace && !($0.unicodeScalars.first?.properties.isEmojiPresentation ?? false) }
        let repeats = plain.count >= 6 && (0...(plain.count - 6)).contains { start in
            let piece = String(Array(plain)[start..<(start + 6)])
            return instruction.contains(piece)
        }
        if !repeats { return text }
        return ["喘", "あえぎ", "自慰", "オナニー"].contains(where: instruction.contains) ? moaning : nil
    }

    /// The words and the voice description from the writer's answer, or nil when either is missing.
    public static func parse(_ reply: String) -> (text: String, caption: String)? {
        var text = "", caption = ""
        for line in reply.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("TEXT:") { text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            if trimmed.uppercased().hasPrefix("CAPTION:") { caption = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        }
        return text.isEmpty || caption.isEmpty ? nil : (text, caption)
    }
}
