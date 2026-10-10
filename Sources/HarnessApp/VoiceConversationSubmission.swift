import Foundation

enum VoiceConversationSubmissionResult: Equatable {
    case accepted(projectID: UUID)
    case paused(message: String)
}
