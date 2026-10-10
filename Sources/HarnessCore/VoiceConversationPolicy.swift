import Foundation

public enum VoiceConversationActivity: String, Codable, Equatable, Sendable {
    case speechStarted
    case speechEnded
}

public enum VoiceSpokenSummaryPolicy {
    public static let maximumCharacters = 240

    /// Voice gives the short answer; the screen remains authoritative for full detail.
    public static func summary(for response: String) -> String {
        let normalized = response
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maximumCharacters else { return normalized }

        let prefix = String(normalized.prefix(maximumCharacters))
        let endings = ["。", "！", "？", "!", "?"]
        let end = prefix.indices.last { index in
            endings.contains(String(prefix[index]))
        }
        let spoken = end.map { String(prefix[...$0]) }
            ?? String(prefix.prefix(maximumCharacters - 1)) + "…"
        return spoken + " 続きは画面に表示しています。"
    }
}
