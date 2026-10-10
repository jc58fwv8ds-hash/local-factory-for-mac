import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

@MainActor
@Suite(.serialized)
struct VoiceConversationSessionTests {
    @Test func speechEndSubmitsTheFinalTurnAfterAGracePeriod() async throws {
        let transcriber = ConversationTranscriptionFixture()
        let speaker = ConversationSpeakerFixture()
        let projectID = UUID()
        let session = VoiceConversationSession(
            transcriber: transcriber,
            speaker: speaker,
            silenceGrace: .milliseconds(5)
        )
        var submitted: [VoiceTranscript] = []
        session.onFinalizedTurn = {
            submitted.append($0)
            return .accepted(projectID: projectID)
        }

        session.start()
        let startTask = session.operationTask
        await startTask?.value
        transcriber.emitActivity(.speechStarted)
        transcriber.emitTranscript(finalized("今日の進み具合を教えて"))
        #expect(submitted.isEmpty)

        transcriber.emitActivity(.speechEnded)
        try await waitUntil { session.phase == .thinking }

        #expect(submitted.map(\.text) == ["今日の進み具合を教えて"])
        #expect(transcriber.finishCount == 1)
        #expect(session.message.contains("考えています"))
    }

    @Test func finalizedTranscriptSubmitsWithoutSpeechDetectorEvents() async throws {
        let transcriber = ConversationTranscriptionFixture()
        let projectID = UUID()
        let session = VoiceConversationSession(
            transcriber: transcriber,
            speaker: ConversationSpeakerFixture(),
            silenceGrace: .milliseconds(5)
        )
        var submitted: [String] = []
        session.onFinalizedTurn = {
            submitted.append($0.text)
            return .accepted(projectID: projectID)
        }

        session.start()
        await session.operationTask?.value
        transcriber.emitTranscript(finalized("進み具合を教えて"))
        try await waitUntil { session.phase == .thinking }

        #expect(submitted == ["進み具合を教えて"])
        #expect(transcriber.finishCount == 1)
    }

    @Test func volatileTranscriptUsesFallbackWhenAudioBoundaryIsMissing() async throws {
        let transcriber = ConversationTranscriptionFixture(
            finalTranscriptOnFinish: "続きを進めて"
        )
        let session = VoiceConversationSession(
            transcriber: transcriber,
            speaker: ConversationSpeakerFixture(),
            transcriptFallbackGrace: .milliseconds(5)
        )
        var submitted: [String] = []
        session.onFinalizedTurn = {
            submitted.append($0.text)
            return .accepted(projectID: UUID())
        }

        session.start()
        await session.operationTask?.value
        transcriber.emitTranscript(VoiceTranscript(
            text: "続きを進めて",
            localeIdentifier: "ja-JP",
            stability: .volatile
        ))
        try await waitUntil { session.phase == .thinking }

        #expect(submitted == ["続きを進めて"])
        #expect(transcriber.finishCount == 1)
    }

    @Test func responseIsSpokenThenListeningRestarts() async throws {
        let transcriber = ConversationTranscriptionFixture()
        let speaker = ConversationSpeakerFixture()
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
        transcriber.emitTranscript(finalized("続けよう"))
        transcriber.emitActivity(.speechEnded)
        try await waitUntil { session.phase == .thinking }

        session.handleResponse("了解。次の確認へ進みます。", projectID: projectID)
        try await waitUntil { transcriber.startCount >= 3 }

        #expect(speaker.spoken == ["了解。次の確認へ進みます。"])
        #expect(session.phase == .listening)
        #expect(session.isActive)
    }

    @Test func resumedSpeechCancelsAPrematureTurnEnd() async throws {
        let transcriber = ConversationTranscriptionFixture()
        let speaker = ConversationSpeakerFixture()
        let session = VoiceConversationSession(
            transcriber: transcriber,
            speaker: speaker,
            silenceGrace: .milliseconds(80)
        )
        var submitCount = 0
        session.onFinalizedTurn = { _ in
            submitCount += 1
            return .accepted(projectID: UUID())
        }

        session.start()
        await session.operationTask?.value
        transcriber.emitActivity(.speechStarted)
        transcriber.emitTranscript(finalized("まだ話しています"))
        transcriber.emitActivity(.speechEnded)
        // Resume synchronously so scheduler load cannot move this simulated event
        // beyond the 80 ms endpoint deadline and turn the test into a clock race.
        transcriber.emitActivity(.speechStarted)
        try await Task.sleep(for: .milliseconds(100))

        #expect(submitCount == 0)
        #expect(transcriber.finishCount == 0)
        #expect(session.phase == .listening)
    }

    @Test func stoppingDuringSpeechNeverRestartsListening() async throws {
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
        transcriber.emitTranscript(finalized("答えて"))
        transcriber.emitActivity(.speechEnded)
        try await waitUntil { session.phase == .thinking }
        session.handleResponse("長い返答です。", projectID: projectID)
        try await waitUntil { session.phase == .speaking }

        session.stop()
        let stopTask = session.operationTask
        await stopTask?.value
        try await Task.sleep(for: .milliseconds(20))

        #expect(speaker.stopCount > 0)
        #expect(transcriber.startCount == 2)
        #expect(session.phase == .idle)
        #expect(!session.isActive)
    }

    @Test func explicitInterruptionStopsOnlySpeechAndStartsTheNextTurn() async throws {
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
        transcriber.emitTranscript(finalized("最初の質問"))
        transcriber.emitActivity(.speechEnded)
        try await waitUntil { session.phase == .thinking }
        session.handleResponse("読み上げ途中の返答です。", projectID: projectID)
        try await waitUntil { session.phase == .speaking }

        session.interruptSpokenResponse()
        try await waitUntil { transcriber.startCount >= 3 }

        #expect(speaker.stopCount == 1)
        #expect(session.phase == .listening)
        #expect(session.isActive)
    }

    @Test func volatileOnlySpeechPausesTheModeInsteadOfSubmitting() async throws {
        let transcriber = ConversationTranscriptionFixture()
        let session = VoiceConversationSession(
            transcriber: transcriber,
            speaker: ConversationSpeakerFixture(),
            silenceGrace: .milliseconds(5)
        )
        var submitted = false
        session.onFinalizedTurn = { _ in
            submitted = true
            return .accepted(projectID: UUID())
        }

        session.start()
        await session.operationTask?.value
        transcriber.emitActivity(.speechStarted)
        transcriber.emitTranscript(VoiceTranscript(
            text: "聞き取り途中",
            localeIdentifier: "ja-JP",
            stability: .volatile
        ))
        transcriber.emitActivity(.speechEnded)
        try await waitUntil { session.phase == .failed }

        #expect(!submitted)
        #expect(!session.isActive)
        #expect(session.message.contains("確定できません"))
    }

    @Test func completedTurnPublishesOnlyEphemeralTimingMetrics() async throws {
        var clock = 0.0
        let transcriber = ConversationTranscriptionFixture {
            clock = 0.4
        }
        let speaker = ConversationSpeakerFixture(holdsSpeech: true)
        let projectID = UUID()
        let session = VoiceConversationSession(
            transcriber: transcriber,
            speaker: speaker,
            silenceGrace: .milliseconds(5),
            now: { clock }
        )
        session.onFinalizedTurn = { _ in .accepted(projectID: projectID) }

        session.start()
        await session.operationTask?.value
        transcriber.emitActivity(.speechStarted)
        transcriber.emitTranscript(finalized("時間を測って"))
        clock = 1
        transcriber.emitActivity(.speechEnded)
        clock = 2
        try await waitUntil { session.phase == .thinking }
        clock = 5.5
        session.handleResponse("短い返答です。", projectID: projectID)
        try await waitUntil { speaker.spoken.count == 1 }
        clock = 7
        speaker.complete()
        try await waitUntil { session.lastMetrics?.outcome == .completed }

        #expect(session.lastMetrics == VoiceConversationMetrics(
            listeningPreparationMilliseconds: 400,
            turnCompletionMilliseconds: 1_000,
            responseMilliseconds: 3_500,
            playbackMilliseconds: 1_500,
            spokenCharacterCount: 7,
            outcome: .completed
        ))
    }

    private func finalized(_ text: String) -> VoiceTranscript {
        VoiceTranscript(
            text: text,
            localeIdentifier: "ja-JP",
            stability: .finalized
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
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

@MainActor
final class ConversationTranscriptionFixture: VoiceTranscriptionProviding {
    let availability = VoiceTranscriptionAvailability.available
    let microphoneAuthorization = VoiceMicrophoneAuthorization.authorized
    private var transcriptHandler: (@MainActor @Sendable (VoiceTranscript) -> Void)?
    private var activityHandler: (@MainActor @Sendable (VoiceConversationActivity) -> Void)?
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private let beforeRecording: (@MainActor () -> Void)?
    private let finalTranscriptOnFinish: String?

    init(
        beforeRecording: (@MainActor () -> Void)? = nil,
        finalTranscriptOnFinish: String? = nil
    ) {
        self.beforeRecording = beforeRecording
        self.finalTranscriptOnFinish = finalTranscriptOnFinish
    }

    func start(
        localeIdentifier: String,
        onTranscript: @escaping @MainActor @Sendable (VoiceTranscript) -> Void,
        onActivity: @escaping @MainActor @Sendable (VoiceConversationActivity) -> Void,
        onStatus: @escaping @MainActor @Sendable (VoiceTranscriptionStatus) -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        startCount += 1
        transcriptHandler = onTranscript
        activityHandler = onActivity
        beforeRecording?()
        onStatus(.recording)
    }

    func finish() async throws {
        finishCount += 1
        if let finalTranscriptOnFinish {
            emitTranscript(VoiceTranscript(
                text: finalTranscriptOnFinish,
                localeIdentifier: "ja-JP",
                stability: .finalized
            ))
        }
    }

    func cancel() async { cancelCount += 1 }

    func emitTranscript(_ transcript: VoiceTranscript) {
        transcriptHandler?(transcript)
    }

    func emitActivity(_ activity: VoiceConversationActivity) {
        activityHandler?(activity)
    }
}

@MainActor
final class ConversationSpeakerFixture: VoiceResponseSpeaking {
    private let holdsSpeech: Bool
    private var continuation: CheckedContinuation<Void, any Error>?
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0

    init(holdsSpeech: Bool = false) {
        self.holdsSpeech = holdsSpeech
    }

    func speak(_ text: String) async throws {
        spoken.append(text)
        guard holdsSpeech else { return }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stop() {
        stopCount += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func complete() {
        continuation?.resume()
        continuation = nil
    }
}
