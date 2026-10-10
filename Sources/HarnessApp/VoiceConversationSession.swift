import Foundation
import HarnessCore
import Observation

@MainActor
@Observable
final class VoiceConversationSession {
    private(set) var isActive = false
    private(set) var phase: VoiceInteractionPhase = .idle
    private(set) var transcript: VoiceTranscript?
    private(set) var lastMetrics: VoiceConversationMetrics?
    private(set) var message = "ボイスモードを押すと会話が始まります"

    @ObservationIgnored private let transcriber: any VoiceTranscriptionProviding
    @ObservationIgnored private let speaker: any VoiceResponseSpeaking
    @ObservationIgnored private let silenceGrace: Duration?
    @ObservationIgnored private let transcriptFallbackGrace: Duration
    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private var turnID: UUID?
    @ObservationIgnored private var heardSpeech = false
    @ObservationIgnored private var bargeInReference: String?
    @ObservationIgnored private var awaitingProjectID: UUID?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var speechTask: Task<Void, Never>?
    @ObservationIgnored private var timing: VoiceConversationTiming?
    @ObservationIgnored private(set) var operationTask: Task<Void, Never>?
    @ObservationIgnored var onFinalizedTurn:
        ((VoiceTranscript) -> VoiceConversationSubmissionResult)?

    init(
        transcriber: any VoiceTranscriptionProviding,
        speaker: any VoiceResponseSpeaking,
        silenceGrace: Duration? = nil,
        transcriptFallbackGrace: Duration = .milliseconds(2_800),
        now: @escaping @MainActor () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.transcriber = transcriber
        self.speaker = speaker
        self.silenceGrace = silenceGrace
        self.transcriptFallbackGrace = transcriptFallbackGrace
        self.now = now
    }

    var availability: VoiceTranscriptionAvailability { transcriber.availability }
    var microphoneAuthorization: VoiceMicrophoneAuthorization {
        transcriber.microphoneAuthorization
    }

    var showsStatus: Bool { isActive || phase == .failed }

    func start() {
        guard !isActive else { return }
        guard availability == .available else {
            phase = .failed
            message = VoiceTranscriptionError.unsupportedSystem.localizedDescription
            return
        }
        isActive = true
        beginListening()
    }

    func stop() {
        isActive = false
        turnID = nil
        awaitingProjectID = nil
        heardSpeech = false
        bargeInReference = nil
        silenceTask?.cancel()
        speechTask?.cancel()
        operationTask?.cancel()
        speaker.stop()
        timing = nil
        operationTask = Task { [weak self, transcriber] in
            await transcriber.cancel()
            guard let self, !self.isActive else { return }
            self.phase = .idle
            self.transcript = nil
            self.message = "ボイスモードを押すと会話が始まります"
            self.operationTask = nil
        }
    }

    func dismissStatus() {
        guard !isActive else { return }
        phase = .idle
        transcript = nil
        message = "ボイスモードを押すと会話が始まります"
    }

    func interruptSpokenResponse() {
        guard isActive, phase == .speaking else { return }
        speechTask?.cancel()
        speechTask = nil
        speaker.stop()
        publishMetrics(outcome: .interrupted)
        phase = .interrupted
        message = "読み上げを止めました。次の言葉を聞きます…"
        beginListening()
    }

    func handleResponse(_ response: String, projectID: UUID) {
        guard isActive, phase == .thinking, awaitingProjectID == projectID else { return }
        awaitingProjectID = nil
        let summary = VoiceSpokenSummaryPolicy.summary(for: response)
        timing?.responseReceivedAt = now()
        timing?.spokenCharacterCount = summary.count
        guard !summary.isEmpty else {
            publishMetrics(outcome: .completed)
            beginListening()
            return
        }
        phase = .speaking
        message = "Local Factoryが答えています。そのまま話しかけても割り込めます"
        timing?.playbackStartedAt = now()
        beginListening(spokenReference: summary)
        speechTask = Task { [weak self, speaker] in
            var outcome = VoiceConversationTurnOutcome.completed
            do {
                try await speaker.speak(summary)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isActive else { return }
                self.message = "読み上げられなかったので、返答を画面に表示しました"
                outcome = .playbackFailed
            }
            guard let self, self.isActive else { return }
            self.speechTask = nil
            self.publishMetrics(outcome: outcome)
            self.beginListening()
        }
    }

    func handleGenerationEnded(projectID: UUID, message: String) {
        guard isActive, phase == .thinking, awaitingProjectID == projectID else { return }
        awaitingProjectID = nil
        timing?.responseReceivedAt = now()
        publishMetrics(outcome: .responseFailed)
        self.message = message
        beginListening()
    }

    private func beginListening(spokenReference: String? = nil) {
        guard isActive else { return }
        let id = UUID()
        if spokenReference == nil {
            timing = VoiceConversationTiming(listeningRequestedAt: now())
        }
        turnID = id
        heardSpeech = false
        transcript = nil
        bargeInReference = spokenReference
        if spokenReference == nil {
            phase = .transcribing
            message = "会話の準備をしています…"
        }
        silenceTask?.cancel()
        operationTask?.cancel()
        operationTask = Task { [weak self, transcriber] in
            do {
                try await transcriber.start(
                    localeIdentifier: "ja-JP",
                    onTranscript: { [weak self] in self?.receive($0, turnID: id) },
                    onActivity: { [weak self] in self?.receive($0, turnID: id) },
                    onStatus: { [weak self] in self?.receive($0, turnID: id) },
                    onFailure: { [weak self] in self?.fail($0, turnID: id) }
                )
                guard let self, self.isCurrentTurn(id) else { return }
                if self.phase != .speaking {
                    self.phase = .listening
                    self.message = "聞いています。話し終わるまで待ちます"
                }
                self.operationTask = nil
            } catch is CancellationError {
                // Ending or replacing a turn is expected.
            } catch {
                self?.fail(error.localizedDescription, turnID: id)
            }
        }
    }

    private func receive(_ update: VoiceTranscript, turnID id: UUID) {
        guard isCurrentTurn(id) else { return }
        if phase == .speaking, let bargeInReference {
            guard VoiceBargeInPolicy.disposition(
                for: update,
                spokenResponse: bargeInReference
            ) == .interrupt else { return }
            acceptAutomaticBargeIn(update, turnID: id)
            return
        }
        transcript = update
        heardSpeech = true
        silenceTask?.cancel()
        message = update.stability == .finalized
            ? "言葉を確認しました。少し待ってから答えます"
            : "「\(VoiceTranscriptFeedback.preview(update.text))」と聞こえています"
        if update.stability == .finalized {
            timing?.speechEndedAt = now()
            scheduleTurnEnd(turnID: id)
        } else {
            scheduleTurnEnd(turnID: id, grace: transcriptFallbackGrace)
        }
    }

    private func receive(_ activity: VoiceConversationActivity, turnID id: UUID) {
        guard isCurrentTurn(id) else { return }
        if phase == .speaking { return }
        switch activity {
        case .speechStarted:
            heardSpeech = true
            silenceTask?.cancel()
            message = "マイクに音が届いています。言葉を聞き取っています…"
        case .speechEnded:
            guard heardSpeech else { return }
            timing?.speechEndedAt = now()
            message = "話し終わりを確認しました。言葉をまとめています…"
            scheduleTurnEnd(turnID: id)
        }
    }

    private func receive(_ status: VoiceTranscriptionStatus, turnID id: UUID) {
        guard isCurrentTurn(id) else { return }
        if phase == .speaking { return }
        switch status {
        case .requestingMicrophone:
            message = "初回だけ、macOSのマイク確認に答えてね。録音は保存しません"
        case .preparingLanguageModel:
            message = "日本語の会話を準備しています…"
        case .downloadingLanguageModel:
            message = "初回だけ、日本語の音声データを準備しています…"
        case .recording:
            if timing?.recordingStartedAt == nil {
                timing?.recordingStartedAt = now()
            }
            phase = .listening
            message = "聞いています。話し終わるまで待ちます"
        case .finalizing:
            phase = .transcribing
            message = "今の言葉を確定しています…"
        }
    }

    private func scheduleTurnEnd(turnID id: UUID, grace override: Duration? = nil) {
        silenceTask?.cancel()
        let grace = override ?? silenceGrace
            ?? VoiceTurnEndpointPolicy.gracePeriod(for: transcript?.text ?? "")
        silenceTask = Task { [weak self] in
            do { try await Task.sleep(for: grace) } catch { return }
            guard let self, self.isCurrentTurn(id) else { return }
            if override != nil { self.timing?.speechEndedAt = self.now() }
            self.finishTurn(turnID: id)
        }
    }

    private func finishTurn(turnID id: UUID) {
        operationTask?.cancel()
        operationTask = Task { [weak self, transcriber] in
            do {
                try await transcriber.finish()
                guard let self, self.isCurrentTurn(id) else { return }
                try self.submitFinalizedTurn()
            } catch is CancellationError {
                // Stopping voice mode cancels the active turn.
            } catch {
                self?.fail(error.localizedDescription, turnID: id)
            }
        }
    }

    private func acceptAutomaticBargeIn(_ update: VoiceTranscript, turnID id: UUID) {
        speechTask?.cancel()
        speechTask = nil
        speaker.stop()
        publishMetrics(outcome: .interrupted)
        timing = VoiceConversationTiming(listeningRequestedAt: now())
        timing?.recordingStartedAt = now()
        transcript = update
        heardSpeech = true
        bargeInReference = nil
        phase = .listening
        message = "割り込みを聞いています。続けて話してね"
        if update.stability == .finalized {
            timing?.speechEndedAt = now()
            scheduleTurnEnd(turnID: id)
        }
    }

    private func submitFinalizedTurn() throws {
        guard let transcript, transcript.stability == .finalized else {
            throw VoiceTranscriptionError.recognitionFailed("最後の言葉を確定できませんでした")
        }
        let authority = VoiceActionAuthorityPolicy.decision(
            transcript: transcript,
            intent: .discussion,
            gesture: .userActivatedConversationMode,
            action: .submitConversation
        )
        guard authority.isAuthorized else {
            throw VoiceTranscriptionError.recognitionFailed(authority.reason)
        }
        switch onFinalizedTurn?(transcript) {
        case .accepted(let projectID):
            timing?.submittedAt = now()
            turnID = nil
            awaitingProjectID = projectID
            phase = .thinking
            message = "Local Factoryが考えています…"
            operationTask = nil
        case .paused(let message):
            isActive = false
            turnID = nil
            phase = .failed
            self.message = message
            publishMetrics(outcome: .submissionPaused)
            operationTask = nil
        case nil:
            throw VoiceTranscriptionError.recognitionFailed("会話を受け付ける準備ができていません")
        }
    }

    private func fail(_ failure: String, turnID id: UUID) {
        guard isCurrentTurn(id) else { return }
        isActive = false
        turnID = nil
        phase = .failed
        message = failure
        publishMetrics(outcome: .transcriptionFailed)
        operationTask?.cancel()
        operationTask = Task { [weak self, transcriber] in
            await transcriber.cancel()
            self?.operationTask = nil
        }
    }

    private func isCurrentTurn(_ id: UUID) -> Bool {
        isActive && turnID == id
    }

    private func publishMetrics(outcome: VoiceConversationTurnOutcome) {
        guard let timing else { return }
        lastMetrics = timing.metrics(endedAt: now(), outcome: outcome)
        self.timing = nil
    }

}
