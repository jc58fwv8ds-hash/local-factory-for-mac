@preconcurrency import AVFAudio
import Foundation
import HarnessCore
import Speech

@available(macOS 26.0, *)
final class AppleSpeechAudioInputBridge: @unchecked Sendable {
    private let converter: AppleSpeechAudioConverter
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onFailure: @MainActor @Sendable (String) -> Void
    private let onActivity: @MainActor @Sendable (VoiceConversationActivity) -> Void
    private let activityDetector = AppleSpeechAudioActivityDetector()

    init(
        converter: AppleSpeechAudioConverter,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onActivity: @escaping @MainActor @Sendable (VoiceConversationActivity) -> Void = { _ in }
    ) {
        self.converter = converter
        self.continuation = continuation
        self.onFailure = onFailure
        self.onActivity = onActivity
    }

    func makeTapBlock() -> AVAudioNodeTapBlock {
        { [weak self] buffer, _ in
            self?.receive(buffer)
        }
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        do {
            if let activity = activityDetector.receive(buffer) {
                Task { @MainActor [onActivity] in
                    onActivity(activity)
                }
            }
            continuation.yield(AnalyzerInput(buffer: try converter.convert(buffer)))
        } catch {
            let message = error.localizedDescription
            Task { @MainActor [onFailure] in
                onFailure(message)
            }
        }
    }
}
