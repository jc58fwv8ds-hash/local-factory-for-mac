import Foundation

public enum VoiceTranscriptFeedback {
    public static let maximumPreviewCharacters = 42

    public static func preview(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maximumPreviewCharacters else { return normalized }
        return String(normalized.prefix(maximumPreviewCharacters - 1)) + "…"
    }
}
