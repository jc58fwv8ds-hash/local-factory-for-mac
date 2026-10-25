import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

@MainActor
@Suite(.serialized)
struct VoiceBargeInSessionTests {
    @Test func spokenReplyCanBeInterruptedByARealCorrectionWithoutClicking() async throws {
        let transcriber = ConversationTranscriptionFixture()
        let speaker = ConversationSpeakerFixture(holdsSpeech: true)
        let projectID = UUID()
        let session = VoiceConversationSession(
            transcriber: transcriber,
            speaker: speaker,
            silenceGrace: .milliseconds(5)
        )
        var submitted: [String] = []
        session.onFinalizedTurn = {
            submitted.append($0.text)
            return .accepted(projectID: projectID)
        }

        session.start()
        await session.operationTask?.value
        transcriber.emitActivity(.speechStarted)
        transcriber.emitTranscript(finalized("最初の質問"))
        transcriber.emitActivity(.speechEnded)
        try await waitUntil { session.phase == .thinking }
        session.handleResponse("最初の回答を説明しています。", projectID: projectID)
        try await waitUntil { session.phase == .speaking && transcriber.startCount >= 2 }

        transcriber.emitActivity(.speechStarted)
        transcriber.emitTranscript(finalized("待って、条件を変えたい"))
        try await waitUntil { speaker.stopCount == 1 }
        transcriber.emitActivity(.speechEnded)
        try await waitUntil { submitted.count == 2 }

        #expect(submitted == ["最初の質問", "待って、条件を変えたい"])
        #expect(session.lastMetrics?.outcome == .interrupted)
        #expect(session.phase == .thinking)
    }

    @Test func playbackEchoAndShortBackchannelsDoNotStealTheFloor() async throws {
        let transcriber = ConversationTranscriptionFixture()
        let speaker = ConversationSpeakerFixture(holdsSpeech: true)
        let projectID = UUID()
        let session = VoiceConversationSession(
            transcriber: transcriber,
            speaker: speaker,
            silenceGrace: .milliseconds(5)
        )
        session.onFinalizedTurn = { _ in .accepted(projectID: projectID) }

        session.start()
        await session.operationTask?.value
        transcriber.emitActivity(.speechStarted)
        transcriber.emitTranscript(finalized("質問"))
        transcriber.emitActivity(.speechEnded)
        try await waitUntil { session.phase == .thinking }
        session.handleResponse("落ち着いて説明を続けます。", projectID: projectID)
        try await waitUntil { session.phase == .speaking && transcriber.startCount >= 2 }

        transcriber.emitTranscript(finalized("落ち着いて説明を続けます"))
        transcriber.emitTranscript(finalized("うん"))
        try await Task.sleep(for: .milliseconds(20))

        #expect(speaker.stopCount == 0)
        #expect(session.phase == .speaking)
        session.stop()
        await session.operationTask?.value
    }

    private func finalized(_ text: String) -> VoiceTranscript {
        VoiceTranscript(
            text: text,
            localeIdentifier: "ja-JP",
            stability: .finalized
        )
    }

    /// Polls until the condition holds. The limit is generous on purpose (2026-10-25): with the whole App test target
    /// starting at once, the main actor did not reach the first test of each voice suite within 1 s (1 run in 4).
    private func waitUntil(
        timeout: Duration = .seconds(10),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("状態の変化を待つ間に時間切れになりました")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
