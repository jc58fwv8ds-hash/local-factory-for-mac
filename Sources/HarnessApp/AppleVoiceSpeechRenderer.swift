@preconcurrency import AVFAudio
import Foundation
import HarnessCore

@MainActor
protocol VoiceSpeechRendering: AnyObject {
    func speak(_ text: String, profile: VoiceModelProfile) async throws
    func stop()
}

@MainActor
final class AppleVoiceSpeechRenderer: NSObject, VoiceSpeechRendering,
    AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let catalog: any SystemVoiceCatalogProviding
    private var continuation: CheckedContinuation<Void, any Error>?

    init(catalog: any SystemVoiceCatalogProviding = AppleSystemVoiceCatalog()) {
        self.catalog = catalog
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, profile: VoiceModelProfile) async throws {
        stop()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        guard profile.engineIdentifier == VoiceModelCatalog.systemEngineIdentifier,
              let voice = catalog.resolveVoice(for: profile) else {
            throw VoiceResponseSpeechError.voiceUnavailable
        }
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = voice
        utterance.rate = min(
            AVSpeechUtteranceMaximumSpeechRate,
            max(AVSpeechUtteranceMinimumSpeechRate, 0.48 * Float(profile.speakingRate))
        )
        utterance.pitchMultiplier = Float(profile.pitchMultiplier)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        complete(throwing: CancellationError())
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.complete() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.complete(throwing: CancellationError()) }
    }

    private func complete(throwing error: (any Error)? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
