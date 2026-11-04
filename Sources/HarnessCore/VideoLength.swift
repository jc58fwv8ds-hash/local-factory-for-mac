import Foundation

/// How long a video should be (2026-11-04, the user: the length must be choosable). From the words of the instruction
/// (「10秒の動画」「1分」), else the choice beside the input field. 「3秒後に爆発する」 is a time in the story, not a length.
public enum VideoLength {
    public static let choices = [3, 5, 10, 15, 20, 30]
    public static let longest = 30
    public static let defaultSeconds = 3
    /// The choice beside the input field.
    public static let settingKey = "harness.videoSeconds"

    public static func seconds(in instruction: String) -> Int? {
        let text = instruction.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? instruction
        func first(_ pattern: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[range])
        }
        if let minutes = first(#"(?<![0-9])([0-9]{1,2})\s*分(?!後|前|の[0-9])"#) { return min(longest, minutes * 60) }
        if let seconds = first(#"(?<![0-9])([0-9]{1,3})\s*秒(?!後|前)"#), seconds > 0 { return min(longest, seconds) }
        return nil
    }
}
