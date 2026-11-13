import Foundation

/// A screenshot attached to a request, as words a model without eyes can use (2026-11-11: the user sent 14Translate's iPhone
/// screen with what was wrong, and the picture never reached the run that fixed it). Each line of text the picture shows,
/// from top to bottom, with how far down the screen it is.
public enum ScreenshotDescription {
    public static func describe(name: String, lines: [VisualRecognizedLine]) -> String? {
        let ordered = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { (top: 1 - ($0.bounds.y + $0.bounds.height), line: $0) }
            .sorted { $0.top < $1.top }
        guard !ordered.isEmpty else { return nil }
        let rows = ordered.map { item -> String in
            let percent = Int((max(0, min(1, item.top)) * 100).rounded())
            let center = item.line.bounds.x + item.line.bounds.width / 2
            let side = center < 0.35 ? "左" : center > 0.65 ? "右" : "中央"
            return "・上から \(percent)%・\(side): \(item.line.text)"
        }
        return "添付の画面写真(\(name))に写っている文字(上から順に、画面の上端からの位置つき):\n" + rows.joined(separator: "\n")
    }
}
