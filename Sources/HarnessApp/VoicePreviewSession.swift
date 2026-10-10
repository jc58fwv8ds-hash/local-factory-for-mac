import HarnessCore
import Observation

@MainActor
@Observable
final class VoicePreviewSession {
    private(set) var playingProfileID: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private let renderer: any VoiceSpeechRendering
    @ObservationIgnored private var task: Task<Void, Never>?

    init(renderer: (any VoiceSpeechRendering)? = nil) {
        self.renderer = renderer ?? AppleVoiceSpeechRenderer()
    }

    func toggle(_ profile: VoiceModelProfile) {
        if playingProfileID == profile.id {
            stop()
            return
        }
        stop()
        errorMessage = nil
        playingProfileID = profile.id
        task = Task { [weak self] in
            do {
                try await self?.renderer.speak(Self.sample, profile: profile)
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled, self?.playingProfileID == profile.id else { return }
            self?.playingProfileID = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        renderer.stop()
        playingProfileID = nil
    }

    private static let sample = "了解しました。状況を整理して、次の一手を短く提案します。"
}
