import Foundation

/// Whether a quickly made picture shows what was asked, judged by the prompt writer looking at it (2026-11-08: the quick way
/// drew two of four requests well in 72 seconds and left the other two out, a clothed portrait and a woman standing dressed;
/// colour and texture could not tell a beige sweater from skin).
public enum PictureCheck {
    /// How many times a picture is made before the last one is kept although it failed the check.
    public static let tries = 3

    /// A broken body fails too (2026-11-14: a picture with four arms, hands on both knees and two more clasped between them).
    /// The place is checked too (2026-11-14: 「場所を香港にして」 was written as a white studio and passed).
    /// What it sees first, then the verdict (2026-11-08: asked for YES or NO alone, the writer passed a woman standing in a
    /// sweater for a request to undress and masturbate).
    public static func request(prompt: String) -> String {
        """
        Look at the attached picture. It was made for this request:
        \(prompt)

        First line: in one short sentence, what the picture shows: where it is, who is in it, how many arms and hands can be seen, how much clothing she wears, her pose, her face and expression, and what her hands are doing.
        Second line: MATCH: YES only if everything the request asks for (the place, the people, the state of dress, the pose, the expression and the action) is clearly visible in the picture; otherwise MATCH: NO. Also MATCH: NO if a body is broken: more or fewer arms, hands, legs or fingers than a person has, a hand coming from nowhere, or bodies merged. Also MATCH: NO if the clothing has a hole, a cut or an opening no real garment has, or if she is still dressed where the request asks her to be bare or the clothing to be open.
        """
    }

    public static func passed(_ reply: String) -> Bool {
        verdict(reply) == true
    }

    /// true for MATCH: YES, false for MATCH: NO, nil when the reply says neither (not a pass).
    public static func verdict(_ reply: String) -> Bool? {
        let text = reply.uppercased().replacingOccurrences(of: " ", with: "")
        if text.contains("MATCH:YES") { return true }
        if text.contains("MATCH:NO") { return false }
        return nil
    }

    /// How the picture that was kept stands (2026-11-25 review: after three failed tries the last picture was kept and
    /// shown as done, with nothing saying it had failed the check).
    public enum Outcome: Equatable, Sendable {
        case passed
        /// Every try failed the check; the last picture is kept anyway.
        case failedKept(tries: Int)
        /// The check did not run or its reply could not be read (a video, no prompt writer, an error).
        case unchecked

        /// What the note about the finished picture says, or "" when it passed or was never meant to be checked.
        public var note: String {
            switch self {
            case .passed: ""
            case .failedKept(let tries): "ただし、確かめでは頼みと合わない所がありました(\(tries) 回作り直しても合格しなかったので、最後の画像を残しています)。"
            case .unchecked: "頼みと合っているかは確かめられませんでした。"
            }
        }
    }
}
