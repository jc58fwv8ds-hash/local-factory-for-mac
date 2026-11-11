import Foundation

/// A model's output that has fallen into repeating blanks (2026-11-10: rewriting SpeechListener.swift the local model wrote
/// spaces for 140 seconds until the 4096-token limit, and the half file could not be read). Stopping as soon as the tail is
/// nothing but blanks saves the wait.
public enum DegenerateOutput {
    public enum Failure: LocalizedError, Equatable {
        case runaway
        public var errorDescription: String? { "AIの出力が空白の繰り返しになったので途中で止めました。もう一度作ってください。" }
    }

    /// The last 1,500 characters are all spaces, tabs or line breaks, or literal 「\n」 and spaces as in a JSON string.
    public static func isRunaway(_ text: String, window: Int = 1_500) -> Bool {
        guard text.count > window else { return false }
        let tail = text.suffix(window).replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\t", with: " ")
        return tail.allSatisfy { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
    }
}
