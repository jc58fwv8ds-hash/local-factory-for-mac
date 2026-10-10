import Foundation
import HarnessCore
import Observation

@MainActor
@Observable
final class VoiceCaptureSession {
    private(set) var phase: VoiceInteractionPhase = .idle
    private(set) var transcript: VoiceTranscript?
    private(set) var message = "押している間だけ話せます"
    private(set) var isPressed = false

    @ObservationIgnored private let provider: any VoiceTranscriptionProviding
    @ObservationIgnored private var captureID: UUID?
    @ObservationIgnored private(set) var operationTask: Task<Void, Never>?
    @ObservationIgnored var onFinalizedDraft: ((VoiceTranscript) -> Void)?

    init(provider: any VoiceTranscriptionProviding) {
        self.provider = provider
    }

    var availability: VoiceTranscriptionAvailability { provider.availability }
    var microphoneAuthorization: VoiceMicrophoneAuthorization {
        provider.microphoneAuthorization
    }

    var showsStatus: Bool {
        phase != .idle || transcript != nil
    }

    func press() {
        guard !isPressed, phase != .listening, phase != .transcribing else { return }
        guard availability == .available else {
            phase = .failed
            message = VoiceTranscriptionError.unsupportedSystem.localizedDescription
            return
        }
        let id = UUID()
        captureID = id
        isPressed = true
        transcript = nil
        phase = .transcribing
        message = "マイクを準備しています…"
        operationTask?.cancel()
        operationTask = Task { [weak self, provider] in
            do {
                try await provider.start(
                    localeIdentifier: "ja-JP",
                    onTranscript: { [weak self] in self?.receive($0, captureID: id) },
                    onActivity: { _ in },
                    onStatus: { [weak self] in self?.receive($0, captureID: id) },
                    onFailure: { [weak self] in self?.fail($0, captureID: id) }
                )
                guard let self, self.captureID == id else { return }
                if self.isPressed {
                    self.phase = .listening
                    self.message = "そのまま話してね。離すと下書きになります"
                    self.operationTask = nil
                } else {
                    try await self.finishProvider(captureID: id)
                }
            } catch is CancellationError {
                // Cancelling a capture is an ordinary user action.
            } catch {
                self?.fail(error.localizedDescription, captureID: id)
            }
        }
    }

    func release() {
        guard isPressed else { return }
        isPressed = false
        guard let id = captureID else { return }
        if phase == .listening {
            beginFinish(captureID: id)
        } else {
            message = "準備が終わったら聞き取りを確定します…"
        }
    }

    func cancel() {
        isPressed = false
        captureID = nil
        operationTask?.cancel()
        operationTask = Task { [weak self, provider] in
            await provider.cancel()
            guard let self else { return }
            self.phase = .idle
            self.transcript = nil
            self.message = "押している間だけ話せます"
            self.operationTask = nil
        }
    }

    func dismissStatus() {
        guard !isPressed, phase != .listening, phase != .transcribing else { return }
        phase = .idle
        transcript = nil
        message = "押している間だけ話せます"
    }

    private func beginFinish(captureID id: UUID) {
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            do {
                try await self?.finishProvider(captureID: id)
            } catch is CancellationError {
                // A newer capture superseded this one.
            } catch {
                self?.fail(error.localizedDescription, captureID: id)
            }
        }
    }

    private func finishProvider(captureID id: UUID) async throws {
        guard captureID == id else { return }
        phase = .transcribing
        message = "最後の言葉を確定しています…"
        try await provider.finish()
        guard captureID == id else { return }
        captureID = nil
        isPressed = false
        if let transcript, transcript.stability == .finalized {
            let decision = VoiceActionAuthorityPolicy.decision(
                transcript: transcript,
                intent: .command,
                gesture: .none,
                action: .insertComposerDraft
            )
            if decision.isAuthorized {
                onFinalizedDraft?(transcript)
                phase = .reviewingTranscript
                message = "入力欄へ下書きとして追加しました。確認してから送ってね"
            } else {
                phase = .failed
                message = decision.reason
            }
        } else {
            phase = .failed
            message = "声を聞き取れませんでした。もう一度、マイクを押したまま話してね。"
        }
        operationTask = nil
    }

    private func receive(_ update: VoiceTranscript, captureID id: UUID) {
        guard captureID == id else { return }
        transcript = update
    }

    private func receive(_ status: VoiceTranscriptionStatus, captureID id: UUID) {
        guard captureID == id else { return }
        switch status {
        case .requestingMicrophone:
            message = "初回だけ、macOSのマイク確認に答えてね。録音は保存しません"
        case .preparingLanguageModel:
            message = "日本語の音声入力を準備しています…"
        case .downloadingLanguageModel:
            message = "初回だけ、日本語の音声データを準備しています…"
        case .recording:
            if isPressed {
                phase = .listening
                message = "そのまま話してね。離すと下書きになります"
            }
        case .finalizing:
            phase = .transcribing
            message = "最後の言葉を確定しています…"
        }
    }

    private func fail(_ failure: String, captureID id: UUID) {
        guard captureID == id else { return }
        captureID = nil
        isPressed = false
        phase = .failed
        message = failure
        operationTask?.cancel()
        operationTask = Task { [weak self, provider] in
            await provider.cancel()
            guard let self, self.phase == .failed else { return }
            self.operationTask = nil
        }
    }
}
