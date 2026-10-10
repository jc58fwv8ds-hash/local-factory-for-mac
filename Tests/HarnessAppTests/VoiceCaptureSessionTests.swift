import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

@MainActor
@Suite(.serialized)
struct VoiceCaptureSessionTests {
    @Test func finalizedSpeechBecomesADraftOnlyAfterTheButtonIsReleased() async {
        let transcript = VoiceTranscript(
            text: "この画面をもう少し見やすくして",
            localeIdentifier: "ja-JP",
            stability: .finalized
        )
        let provider = VoiceTranscriptionFixture(updates: [transcript])
        let session = VoiceCaptureSession(provider: provider)
        var drafted: [VoiceTranscript] = []
        session.onFinalizedDraft = { drafted.append($0) }

        session.press()
        let startTask = session.operationTask
        await startTask?.value
        #expect(session.phase == .listening)
        #expect(drafted.isEmpty)

        session.release()
        let finishTask = session.operationTask
        await finishTask?.value
        #expect(session.phase == .reviewingTranscript)
        #expect(drafted == [transcript])
        #expect(provider.finishCount == 1)
    }

    @Test func volatileSpeechNeverBecomesAComposerDraft() async {
        let provider = VoiceTranscriptionFixture(updates: [VoiceTranscript(
            text: "聞き取り途中",
            localeIdentifier: "ja-JP",
            stability: .volatile
        )])
        let session = VoiceCaptureSession(provider: provider)
        var drafted = false
        session.onFinalizedDraft = { _ in drafted = true }

        session.press()
        await session.operationTask?.value
        session.release()
        await session.operationTask?.value

        #expect(session.phase == .failed)
        #expect(!drafted)
    }

    @Test func cancellationDiscardsPendingRecognitionAndLateCallbacks() async throws {
        let provider = VoiceTranscriptionFixture(startDelay: .milliseconds(200))
        let session = VoiceCaptureSession(provider: provider)
        var drafted = false
        session.onFinalizedDraft = { _ in drafted = true }

        session.press()
        let abandonedStart = session.operationTask
        session.cancel()
        let cancelTask = session.operationTask
        await abandonedStart?.value
        await cancelTask?.value
        provider.emit(VoiceTranscript(
            text: "遅れて届いた古い結果",
            localeIdentifier: "ja-JP",
            stability: .finalized
        ))

        #expect(session.phase == .idle)
        #expect(session.transcript == nil)
        #expect(!drafted)
        #expect(provider.cancelCount == 1)
    }

    @Test func olderSystemsExplainTheLimitWithoutCallingTheProvider() async {
        let provider = VoiceTranscriptionFixture(availability: .requiresMacOS26)
        let session = VoiceCaptureSession(provider: provider)
        session.press()
        await session.operationTask?.value

        #expect(session.phase == .failed)
        #expect(session.message.contains("macOS 26"))
        #expect(provider.startCount == 0)
    }
}

@MainActor
private final class VoiceTranscriptionFixture: VoiceTranscriptionProviding {
    let availability: VoiceTranscriptionAvailability
    let microphoneAuthorization = VoiceMicrophoneAuthorization.authorized
    private let updates: [VoiceTranscript]
    private let startDelay: Duration?
    private var transcriptHandler: (@MainActor @Sendable (VoiceTranscript) -> Void)?
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    init(
        availability: VoiceTranscriptionAvailability = .available,
        updates: [VoiceTranscript] = [],
        startDelay: Duration? = nil
    ) {
        self.availability = availability
        self.updates = updates
        self.startDelay = startDelay
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
        if let startDelay { try await Task.sleep(for: startDelay) }
        try Task.checkCancellation()
        onStatus(.recording)
        updates.forEach(onTranscript)
    }

    func finish() async throws { finishCount += 1 }

    func cancel() async { cancelCount += 1 }

    func emit(_ transcript: VoiceTranscript) {
        transcriptHandler?(transcript)
    }
}
