import Foundation

/// Prompt-only formatting. Never write excerpts or inferred summaries back to conversation storage.
enum PromptReferenceText {
    static let sourceMarker = "HARNESS_SOURCE_REFERENCE"
    static let externalReviewMarker = "HARNESS_EXTERNAL_REVIEW_REFERENCE"
    static let visualTextMarker = "HARNESS_VISUAL_TEXT_REFERENCE"
    static let documentTextMarker = "HARNESS_DOCUMENT_REFERENCE"

    static func isQuotedReference(_ content: String, marker: String) -> Bool {
        content.hasPrefix("[\(marker)]\n") && content.hasSuffix("\n[END_\(marker)]")
    }

    struct FormattedReference: Sendable {
        let message: InferenceMessage
        let wasTruncated: Bool
    }

    static func excerpt(_ text: String, maximumCharacters: Int) -> String {
        let limit = max(0, maximumCharacters)
        guard text.count > limit else { return text }
        let marker = "\n（中間を省略・全文ではありません）\n"
        guard limit > marker.count else { return String(marker.prefix(limit)) }
        let available = limit - marker.count
        return String(text.prefix(available / 2)) + marker + String(text.suffix(available - available / 2))
    }

    static func localAnswer(
        _ content: String,
        previous: Bool = false,
        maximumCharacters: Int
    ) -> FormattedReference {
        let heading = localAnswerHeading(previous: previous)
        let body = excerpt(content, maximumCharacters: min(8_000, max(0, maximumCharacters - heading.count)))
        return FormattedReference(
            message: InferenceMessage(role: .assistant, content: heading + body),
            wasTruncated: body != content
        )
    }

    static func localAnswerHeading(previous: Bool) -> String {
        let label = previous ? "前回のローカル回答" : "過去のローカル回答"
        return "\(label)（提案・参考。実装・実行・検証の証拠ではありません）:\n"
    }

    static func quotedMessage(
        content: String,
        marker: String,
        description: String,
        maximumCharacters: Int
    ) -> FormattedReference {
        let start = "[\(marker)]"
        let end = "[END_\(marker)]"
        let heading = start + "\n" + description + "\n"
        let ending = "\n" + end
        // Quote first, then bound the body; never cut away the opening or closing boundary.
        let neutralized = String(content.prefix(maximumCharacters))
            .replacingOccurrences(of: start, with: "[reference-marker-removed]")
            .replacingOccurrences(of: end, with: "[reference-end-marker-removed]")
        let quoted = neutralized.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n")
        let room = max(0, maximumCharacters - heading.count - ending.count)
        let truncation = "\n> （参考資料を上限で省略）"
        let body = quoted.count <= room ? quoted
            : String(quoted.prefix(max(0, room - truncation.count))) + String(truncation.prefix(room))
        return FormattedReference(
            message: InferenceMessage(role: .user, content: heading + body + ending),
            wasTruncated: content.count > maximumCharacters || quoted.count > room
        )
    }
}
