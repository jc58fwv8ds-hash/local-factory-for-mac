import Foundation

/// Reserve room for the user's changing intent independently of verbose model/external responses.
public struct ConversationPromptHistory: Sendable {
    public static let maximumCharacters = 24_000
    public let messages: [InferenceMessage]
    public let wasTruncated: Bool

    public init(project: HarnessProject) {
        let continuation = ContinuationResponsePolicy(project: project)
        var selected: [InferenceMessage] = []
        var userRoom = Self.maximumCharacters / 2
        var referenceRoom = Self.maximumCharacters - userRoom
        var userCount = 0
        var referenceCount = 0
        var truncated = false
        let latestUserID = ProjectInstructionContext.userMessages(in: project).last?.id

        for message in project.conversation.reversed() {
            let isUser = message.role == .user && (message.origin == .user || message.origin == .remoteUser)
            let prompt: InferenceMessage
            if isUser {
                guard userCount < 12, userRoom > 0 else {
                    truncated = true
                    continue
                }
                let raw = message.id == continuation?.instruction.id
                    ? continuation?.instructionMessage.content ?? message.content : message.content
                let shouldGuard = message.id == latestUserID
                let clarification = shouldGuard
                    ? ConversationClarifyingContext.text(for: project, excluding: message.id) : nil
                let guardLength = shouldGuard
                    ? ConversationResponseGuard.appending(
                        to: "", clarifyingContext: clarification
                    ).count : 0
                let messageBudget = min(4_000, userRoom)
                let excerpt = PromptReferenceText.excerpt(
                    raw, maximumCharacters: max(1, messageBudget - guardLength)
                )
                truncated = truncated || excerpt != raw
                let content = shouldGuard
                    ? ConversationResponseGuard.appending(
                        to: excerpt, clarifyingContext: clarification
                    ) : excerpt
                prompt = InferenceMessage(role: .user, content: content)
                userRoom -= content.count
                userCount += 1
            } else {
                guard referenceCount < 6, referenceRoom >= 512 else {
                    truncated = true
                    continue
                }
                let budget = min(8_100, referenceRoom)
                let reference: PromptReferenceText.FormattedReference
                if message.origin == .externalReview {
                    reference = ExternalReviewPromptBoundary.reference(
                        from: message.content, maximumCharacters: budget
                    )
                } else {
                    reference = PromptReferenceText.localAnswer(
                        message.content, previous: message.id == continuation?.previousResponse.id,
                        maximumCharacters: budget
                    )
                }
                prompt = reference.message
                truncated = truncated || reference.wasTruncated
                referenceRoom -= prompt.content.count
                referenceCount += 1
            }
            selected.append(prompt)
        }
        messages = Array(selected.reversed())
        wasTruncated = truncated
    }
}
