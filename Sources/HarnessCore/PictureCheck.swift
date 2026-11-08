import Foundation

/// Whether a quickly made picture shows what was asked, judged by the prompt writer looking at it (2026-11-08: the quick way
/// drew two of four requests well in 72 seconds and left the other two out, a clothed portrait and a woman standing dressed;
/// colour and texture could not tell a beige sweater from skin).
public enum PictureCheck {
    /// What it sees first, then the verdict (2026-11-08: asked for YES or NO alone, the writer passed a woman standing in a
    /// sweater for a request to undress and masturbate).
    public static func request(prompt: String) -> String {
        """
        Look at the attached picture. It was made for this request:
        \(prompt)

        First line: in one short sentence, what the picture shows: how much clothing she wears, her pose, and what her hands are doing.
        Second line: MATCH: YES only if the state of dress, the pose and the action the request asks for are all clearly visible in the picture; otherwise MATCH: NO. Also MATCH: NO if the clothing has a hole, a cut or an opening no real garment has, or if she is still dressed where the request asks her to be bare or the clothing to be open.
        """
    }

    public static func passed(_ reply: String) -> Bool {
        reply.uppercased().replacingOccurrences(of: " ", with: "").contains("MATCH:YES")
    }
}
