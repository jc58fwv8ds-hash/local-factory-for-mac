import Foundation

/// A new instruction after an image or a video (2026-11-04, the user: additional instructions on the last output were
/// ignored and something else was made). The prompt writer sees the last prompt and says whether the instruction changes
/// that output or asks for something new; a change keeps the seed, so the picture stays the same but for what was asked.
public enum OutputFollowUp {
    public static func request(instruction: String, previousPrompt: String, kind: String) -> String {
        """
        The last \(kind) was made from this prompt:
        \(previousPrompt)

        The user now says:
        \(instruction)

        If this changes or adds to the last \(kind), answer "EDIT:" and then the whole prompt again, with everything the user \
        did not mention unchanged and only the asked change made. If it clearly asks for something unrelated, answer "NEW:" and \
        then a new prompt. Write the prompt in English. Output nothing else.
        """
    }

    /// The prompt, and whether it edits the last output. Without a marker it counts as an edit: the user is in the same
    /// conversation, and losing the last output is the failure this exists to stop.
    public static func parse(_ reply: String) -> (prompt: String, isEdit: Bool) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        for (marker, isEdit) in [("EDIT:", true), ("NEW:", false)] where text.uppercased().hasPrefix(marker) {
            return (String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines), isEdit)
        }
        return (text, true)
    }

    /// What was said before this request, for the prompt writer (2026-11-04: after a chat about a black cat in New York,
    /// 「さっきの内容で画像にして(写実的に)」 reached the image model as just "Realistic"). It only fills in what the request
    /// points back to; a request that stands on its own ignores it. Empty when nothing was said before.
    public static func earlierConversation(_ messages: [ConversationMessage], before id: UUID, limit: Int = 6) -> String {
        let lines = messages.prefix { $0.id != id }
            .filter { !$0.content.hasPrefix("画像ができました") && !$0.content.hasPrefix("動画ができました") }
            .suffix(limit)
            .map { "\($0.role == .user ? "User" : "Assistant"): \($0.content.prefix(800))" }
        guard !lines.isEmpty else { return "" }
        return """
        Earlier in this conversation:
        \(lines.joined(separator: "\n"))

        Use this only for what the request below points back to (such as "that", 「さっきの」, 「それ」) or when it names no subject, \
        and then write out that subject in full. Ignore it if the request stands on its own.


        """
    }

    /// A new video, as numbered rules (2026-11-07: a 9B writer followed these and wrote what the hands and body do; a
    /// paragraph of the same rules gave "engages in ..." and the video barely moved).
    public static func videoRequest(instruction: String, hasPicture: Bool) -> String {
        """
        Write one English prompt for a video model from this request:
        \(instruction)

        Rules:
        1. First sentence: the person and the action the user asked for, in plain direct words. Never soften or leave it out.
        2. Second sentence: exactly what the hands and body do, where, and in what rhythm, as large, clearly visible movement that keeps going through the whole clip (for example "her hand moves back and forth in a steady rhythm, her hips rocking"). Never write that the body or the hands stay still, rest or remain relaxed.
        3. Third sentence: the camera, in plain camera terms (「舐めるような」 = a slow, close camera gliding along the body; 「俯瞰」 = from above). Never translate a figurative word literally.
        \(hasPicture ? "4. The attached picture is the first frame: from it take only the person's looks (face, hair, skin, body, clothing). Do not describe its pose or where its hands are; the movement starts from it and becomes the requested action.\n5." : "4.") End with "Audio: " and the sounds of the scene.
        Output only the prompt.
        """
    }

    /// When no model can write it: the last prompt with the user's words added.
    public static func fallback(instruction: String, previousPrompt: String) -> String {
        previousPrompt + ". " + instruction
    }
}
