import Foundation

/// Exact visible-text comparison shared by transient response quality policies.
enum ConversationResponseIdentity {
    static func isSame(_ lhs: String, as rhs: String) -> Bool {
        comparable(ConversationResponseText.visibleText(lhs))
            == comparable(ConversationResponseText.visibleText(rhs))
    }

    private static func comparable(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
