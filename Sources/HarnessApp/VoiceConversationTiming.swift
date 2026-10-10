import Foundation
import HarnessCore

struct VoiceConversationTiming {
    let listeningRequestedAt: TimeInterval
    var recordingStartedAt: TimeInterval?
    var speechEndedAt: TimeInterval?
    var submittedAt: TimeInterval?
    var responseReceivedAt: TimeInterval?
    var playbackStartedAt: TimeInterval?
    var spokenCharacterCount = 0

    func metrics(
        endedAt: TimeInterval,
        outcome: VoiceConversationTurnOutcome
    ) -> VoiceConversationMetrics {
        VoiceConversationMetrics(
            listeningPreparationMilliseconds: duration(
                from: listeningRequestedAt,
                to: recordingStartedAt
            ),
            turnCompletionMilliseconds: duration(
                from: speechEndedAt,
                to: submittedAt
            ),
            responseMilliseconds: duration(
                from: submittedAt,
                to: responseReceivedAt
            ),
            playbackMilliseconds: duration(
                from: playbackStartedAt,
                to: playbackStartedAt == nil ? nil : endedAt
            ),
            spokenCharacterCount: spokenCharacterCount,
            outcome: outcome
        )
    }

    private func duration(from start: TimeInterval?, to end: TimeInterval?) -> Int? {
        guard let start, let end else { return nil }
        return Int((max(0, end - start) * 1_000).rounded())
    }
}
