import Foundation

/// Remove only Harness's own leading reference labels, not quoted or embedded user content.
public enum ConversationResponseText {
    public static func visibleText(_ raw: String, isComplete: Bool = true) -> String {
        let headings = [false, true].flatMap {
            let heading = PromptReferenceText.localAnswerHeading(previous: $0)
            return [heading, heading.replacingOccurrences(of: "\n", with: "\r\n")]
        }
        var result = raw
        while true {
            let candidate = String(result.drop(while: { $0.isWhitespace }))
            if let heading = headings.first(where: { candidate.hasPrefix($0) }) {
                result = String(candidate.dropFirst(heading.count))
                continue
            }
            if isComplete, headings.contains(where: { candidate == $0.trimmingCharacters(in: .newlines) }) {
                return ""
            }
            // A partial label is hidden while streaming, but a real short answer like "過去" survives EOF.
            if !isComplete, !candidate.isEmpty, headings.contains(where: { $0.hasPrefix(candidate) }) {
                return ""
            }
            return result
        }
    }
}
