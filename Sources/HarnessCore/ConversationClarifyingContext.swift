import Foundation

/// A bounded, raw user-only reminder. This is not a summary, preference store, or new authority.
public enum ConversationClarifyingContext {
    public static let maximumCharacters = 1_800
    public static let maximumMessageCharacters = 500
    public static let maximumMessageCount = 8

    public static func text(
        for project: HarnessProject,
        excluding messageID: UUID
    ) -> String? {
        var remaining = maximumCharacters
        var selected: [String] = []
        for message in ProjectInstructionContext.userMessages(in: project).reversed()
            where message.id != messageID {
            guard selected.count < maximumMessageCount, remaining > 0 else { break }
            let excerpt = PromptReferenceText.excerpt(
                message.content.trimmingCharacters(in: .whitespacesAndNewlines),
                maximumCharacters: min(maximumMessageCharacters, remaining)
            )
            guard !excerpt.isEmpty else { continue }
            selected.append(excerpt)
            remaining -= excerpt.count
        }
        guard !selected.isEmpty else { return nil }
        return selected.reversed().map { "- \($0)" }.joined(separator: "\n")
    }
}
