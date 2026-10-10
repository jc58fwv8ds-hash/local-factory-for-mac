import Foundation

/// Content-free prompt diagnostics. Counts Swift characters, not bytes or tokens.
public struct InferencePromptComposition: Equatable, Sendable, Encodable {
    public let messageCount: Int
    public let systemCharacters: Int
    public let userCharacters: Int
    public let assistantCharacters: Int
    public let sourceCharacters: Int
    public let externalReviewCharacters: Int
    public let imageCount: Int
    public let imageBytes: Int

    public var totalCharacters: Int {
        systemCharacters + userCharacters + assistantCharacters
            + sourceCharacters + externalReviewCharacters
    }

    init(messages: [InferenceMessage], images: [InferenceImage] = []) {
        var system = 0
        var user = 0
        var assistant = 0
        var source = 0
        var externalReview = 0
        for message in messages {
            switch message.role {
            case .system:
                system += message.content.count
            case .assistant:
                assistant += message.content.count
            case .user where PromptReferenceText.isQuotedReference(
                message.content, marker: PromptReferenceText.sourceMarker
            ):
                source += message.content.count
            case .user where PromptReferenceText.isQuotedReference(
                message.content, marker: PromptReferenceText.externalReviewMarker
            ):
                externalReview += message.content.count
            case .user:
                user += message.content.count
            }
        }
        messageCount = messages.count
        systemCharacters = system
        userCharacters = user
        assistantCharacters = assistant
        sourceCharacters = source
        externalReviewCharacters = externalReview
        imageCount = images.count
        imageBytes = images.reduce(0) { partial, image in
            partial.addingReportingOverflow(image.data.count).overflow
                ? Int.max
                : partial + image.data.count
        }
    }
}
