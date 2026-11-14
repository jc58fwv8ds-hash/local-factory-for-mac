import Foundation

/// Every part of the user's words is in the prompt that is sent (2026-11-14, the user: 「ユーザーの文章を、場所問わず無視する
/// 作りってダメだよ。ユーザーの意思に反したものをユーザーの計算資源を利用して勝手に生成するってことでしょ？」「行動もポーズ、顔、
/// 表情、セリフの内容色々動画って要素があるよ」). After the prompt is written, the writer lists what the user asked for and puts
/// back whatever the prompt left out and takes out what the words replace (2026-11-14: 「場所を香港にして」 kept 「a plain
/// white studio setting」 beside 「The location is Hong Kong.」 and the white backdrop won), instead of each kind of element being fixed one at a time after it was lost.
public enum RequestCoverage {
    public static func request(instruction: String, prompt: String, isVideo: Bool) -> String {
        """
        The user asked for \(isVideo ? "a video" : "a picture") with these words:
        \(instruction)

        This prompt was written for the \(isVideo ? "video" : "picture") model:
        \(prompt)

        Go through every element of the user's words: who; the place and its details (a city or building, but also, for example, a room of an apartment or the alcove of a wooden Japanese house); what they do; the pose; the face and expression; clothing or its absence; things in the scene; words they say\(isVideo ? "; the camera; when each thing happens and how long the video is" : ""); the style. Leave out nothing the user wrote and add nothing they did not.
        If the prompt states every element and keeps nothing the user's words change, answer exactly: OK
        Otherwise answer "FIXED:" and then the whole prompt again in English, with every missing element written plainly where it belongs, and anything the user's words change or contradict (an old place or background, such as a studio or a plain backdrop, old clothing, an old pose) taken out, not kept beside the new one. A place is written as the scene with a few things one sees there. Nothing else changed.
        """
    }

    /// The prompt to send: the fixed one when the writer gave one, else the prompt as it was.
    public static func apply(_ reply: String, to prompt: String) -> String {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: "FIXED:") else { return prompt }
        let fixed = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return fixed.count >= prompt.count / 2 ? fixed : prompt
    }

    /// A studio or plain backdrop left in a prompt whose request moves the place (「場所を…」「背景を…」), taken out as a last
    /// net when the writer kept both (2026-11-14).
    public static func droppingOldBackdrop(_ prompt: String, instruction: String) -> String {
        guard ["場所", "背景", "舞台", "ロケーション"].contains(where: instruction.contains) else { return prompt }
        let pattern = #",?\s*\b(in|against|on|before|with)\s+(a|an|the)\s+[^,.]*?\b(studio|backdrop|background)\b[^,.]*"#
        let dropped = prompt.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        return dropped.replacingOccurrences(of: #"\s+([,.])"#, with: "$1", options: .regularExpression)
    }

    /// One focused question about the place, which a small writer answers where a whole rewrite fails (2026-11-14, round 2:
    /// the 9B writer copied the last prompt and only added 「The location is Hong Kong.」, and the picture stayed white).
    public static func placeQuestion(instruction: String, previousPrompt: String?) -> String {
        """
        Where does this request put the scene?
        \(instruction)
        \(previousPrompt.map { "(The picture before it was made from: \($0))\n" } ?? "")
        If the request names or changes a place or background (a city, a building, a room, a landscape, a backdrop), answer with one English phrase that starts with "in", "at" or "on" and an article, naming that place with two or three things one sees there (for example: in a narrow Hong Kong street lined with neon signs and Chinese shop signs, people passing by). Otherwise answer exactly: NONE
        """
    }

    /// The prompt with the place phrase as its scene: 「The location is …」 sentences and old backdrops out, the phrase put
    /// into the first sentence, where the picture model weighs it.
    public static func placing(_ reply: String, in prompt: String, instruction: String) -> String {
        var phrase = reply.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
        phrase = phrase.trimmingCharacters(in: CharacterSet(charactersIn: " .\"'"))
        guard phrase.range(of: #"^(in|at|on)\s+\S+"#, options: [.regularExpression, .caseInsensitive]) != nil,
              !phrase.uppercased().hasPrefix("NONE") else { return prompt }
        var text = prompt.replacingOccurrences(of: #"\s*The (location|setting|place|scene|background) is [^.]*\."#, with: "",
                                               options: [.regularExpression, .caseInsensitive])
        text = droppingOldBackdrop(text, instruction: "場所")
        guard let end = text.range(of: ".") else { return text + " " + phrase + "." }
        return text[..<end.lowerBound] + ", " + phrase + text[end.lowerBound...]
    }
}
