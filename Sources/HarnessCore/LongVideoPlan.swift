import Foundation

/// A long video as a row of short scenes (2026-11-08, the user: make short clips one after another into a long video). The
/// prompt writer splits the request into scenes; each becomes a clip that starts where the one before ended.
public enum LongVideoPlan {
    /// One clip's length in seconds. Three (2026-11-08): the video model puts its motion into the first two or three
    /// seconds and then nearly stops (hand-area motion per second over a 10-second clip: 37.8, 12.9, 9.5, 6.4 … 3.2;
    /// a 3-second clip averaged 41.5, a 10-second one 8.9), for about the same time per second of video.
    public static let sceneSeconds = 3
    /// The longest video made this way (30 minutes, 2026-11-08, the user: up to about 30 minutes, so places, people and
    /// actions can change along the way). About a day of work at the present speed.
    public static let longestSeconds = 1800
    /// Scenes per chapter: a long video is first written as chapters (place, clothing, action), then each chapter as scenes.
    public static let scenesPerChapter = 10

    public struct Scene: Codable, Equatable, Sendable {
        public var prompt: String
        public var text: String
        public var caption: String
        /// The pose or place changes so much that the scene starts from a new picture of the person instead of the last
        /// frame (2026-11-08: 「ソファに寝そべって…壁に寄りかかって」 stayed standing for 30 seconds, every scene starting
        /// from the standing frame before it).
        public var restart: Bool
        public init(prompt: String, text: String = "", caption: String = "", restart: Bool = false) {
            self.prompt = prompt; self.text = text; self.caption = caption; self.restart = restart
        }
        enum CodingKeys: String, CodingKey { case prompt, text, caption, restart }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            prompt = try c.decode(String.self, forKey: .prompt)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
            restart = try c.decodeIfPresent(Bool.self, forKey: .restart) ?? false
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
        seconds > sceneSeconds + 1 ? Int((Double(seconds) / Double(sceneSeconds)).rounded()) : nil
    }

    /// Words for how strong the motion is, rising from the first scene to the last (2026-11-08, Muse's review: 「だんだん
    /// 激しく」 measured weaker scene by scene; the writer is not left to say it). 2026-11-09, the user: the motion was too
    /// fast and the moving hand broke up, so it grows in strength (deeper, firmer, the body answering), not in speed.
    public static func intensity(scene: Int, of scenes: Int) -> String {
        let levels = ["Her movements are slow and gentle, her breathing soft.",
                      "Her movements grow firmer and deeper at a steady pace, her breathing heavy.",
                      "Her movements are strong and deep, her hips rocking with them, her breathing ragged.",
                      "Her movements are intense, her whole body trembling, at the edge of climax."]
        guard scenes > 1 else { return levels[1] }
        return levels[min(levels.count - 1, scene * levels.count / scenes)]
    }

    public static func writerRequest(instruction: String, videoPrompt: String, scenes: Int, withVoice: Bool) -> String {
        """
        A \(scenes * sceneSeconds)-second video is made as \(scenes) scenes of \(sceneSeconds) seconds, each starting where the one before ended, with the same person throughout.
        The request:
        \(instruction)
        The whole video in one prompt:
        \(videoPrompt)

        Write the \(scenes) scenes in order, so that together they tell what the request asks, moving forward from scene to scene. For each scene: "prompt", one English prompt for the video model (start with what the person does, as continuous motion through the scene; the same person and place unless the request changes them; end with "Audio: " and the sounds). "restart": true when the scene's pose or place is very different from where the scene before ends (for example standing to lying on a sofa, or a new room), so it starts from a new picture; otherwise false. The first scene is true when its pose or place differs from the starting picture.\(withVoice ? " \"text\": what she says or voices in that scene, in Japanese, at most 40 characters (keep any words the user put in 「」 exactly; moaning like 「🥵あっ…んっ…🌬はぁ…」 when that is asked), or empty. Keep words and hand actions in separate scenes: a scene where she says words shows her talking, face and upper body, without the hand action; a scene with the hand action has no words, only moans and breaths or nothing. \"caption\": her voice in Japanese, the same in every scene." : "")
        Answer only JSON: {"scenes": [{"prompt": "...", "restart": false\(withVoice ? ", \"text\": \"...\", \"caption\": \"...\"" : "")}]}
        """
    }

    /// The chapters of a long video: what each part of it shows, in order, so it moves on instead of repeating.
    public static func chapterRequest(instruction: String, videoPrompt: String, chapters: Int) -> String {
        """
        A long video (\(chapters) parts of \(scenesPerChapter * sceneSeconds) seconds) is made from this request, with the same person throughout unless it asks otherwise:
        \(instruction)
        The whole video in one prompt:
        \(videoPrompt)

        Write the \(chapters) parts in order, so that together they tell what the request asks and something changes from part to part (the place, the clothing, the pose or the action), in the order the request gives or a natural order. Each part: one English sentence saying where she is, what she wears and what she does.
        Answer only JSON: {"chapters": ["...", "..."]}
        """
    }

    /// The chapters from the writer's answer; missing ones repeat the whole-video prompt.
    public static func parseChapters(_ reply: String, chapters: Int, fallback: String) -> [String] {
        var parsed: [String] = []
        if let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
           let data = String(reply[start...end]).data(using: .utf8),
           let object = try? JSONDecoder().decode([String: [String]].self, from: data), let list = object["chapters"] {
            parsed = list.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        parsed = Array(parsed.prefix(chapters))
        while parsed.count < chapters { parsed.append(parsed.last ?? fallback) }
        return parsed
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

extension Optional {
    /// `map` for an async transform.
    public func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        switch self { case .some(let value): await transform(value); case .none: nil }
    }
}
