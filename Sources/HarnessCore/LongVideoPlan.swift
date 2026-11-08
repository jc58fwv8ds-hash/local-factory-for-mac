import Foundation

/// A long video as a row of short scenes (2026-11-08, the user: make short clips one after another into a long video). The
/// prompt writer splits the request into scenes; each becomes a clip that starts where the one before ended.
public enum LongVideoPlan {
    /// One clip's length in seconds.
    public static let sceneSeconds = 10
    /// The longest video made this way (5 minutes, about 30 scenes).
    public static let longestSeconds = 300

    public struct Scene: Codable, Equatable, Sendable {
        public var prompt: String
        public var text: String
        public var caption: String
        public init(prompt: String, text: String = "", caption: String = "") { self.prompt = prompt; self.text = text; self.caption = caption }
        enum CodingKeys: String, CodingKey { case prompt, text, caption }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            prompt = try c.decode(String.self, forKey: .prompt)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        }
    }

    /// The length asked for in words, without the single-clip limit (「1分の動画」 is 60), or nil.
    public static func requestedSeconds(in instruction: String) -> Int? {
        let text = instruction.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? instruction
        func first(_ pattern: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[range])
        }
        if let minutes = first(#"(?<![0-9])([0-9]{1,2})\s*分(?!後|前|の[0-9])"#) { return min(longestSeconds, minutes * 60) }
        if let seconds = first(#"(?<![0-9])([0-9]{1,3})\s*秒(?!後|前)"#), seconds > 0 { return min(longestSeconds, seconds) }
        return nil
    }

    /// How many scenes a length needs, or nil when one clip is enough.
    public static func sceneCount(seconds: Int) -> Int? {
        seconds > sceneSeconds * 3 / 2 ? Int((Double(seconds) / Double(sceneSeconds)).rounded()) : nil
    }

    public static func writerRequest(instruction: String, videoPrompt: String, scenes: Int, withVoice: Bool) -> String {
        """
        A \(scenes * sceneSeconds)-second video is made as \(scenes) scenes of \(sceneSeconds) seconds, each starting where the one before ended, with the same person throughout.
        The request:
        \(instruction)
        The whole video in one prompt:
        \(videoPrompt)

        Write the \(scenes) scenes in order, so that together they tell what the request asks, moving forward from scene to scene. For each scene: "prompt", one English prompt for the video model (start with what the person does, as continuous motion through the scene; the same person and place unless the request changes them; end with "Audio: " and the sounds).\(withVoice ? " \"text\": what she says or voices in that scene, in Japanese, at most 40 characters (keep any words the user put in 「」 exactly; moaning like 「🥵あっ…んっ…🌬はぁ…」 when that is asked), or empty. \"caption\": her voice in Japanese, the same in every scene." : "")
        Answer only JSON: {"scenes": [{"prompt": "..."\(withVoice ? ", \"text\": \"...\", \"caption\": \"...\"" : "")}]}
        """
    }

    /// The scenes from the writer's answer; when it gives fewer or none, the whole-video prompt fills the rest.
    public static func parse(_ reply: String, scenes: Int, fallback: String) -> [Scene] {
        var parsed: [Scene] = []
        if let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
           let data = String(reply[start...end]).data(using: .utf8),
           let object = try? JSONDecoder().decode([String: [Scene]].self, from: data), let list = object["scenes"] {
            parsed = list.filter { !$0.prompt.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        parsed = Array(parsed.prefix(scenes))
        while parsed.count < scenes { parsed.append(Scene(prompt: fallback)) }
        return parsed
    }
}
