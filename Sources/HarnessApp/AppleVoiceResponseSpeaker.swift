import HarnessCore

@MainActor
final class AppleVoiceResponseSpeaker: VoiceResponseSpeaking {
    private let renderer: any VoiceSpeechRendering
    private let profileProvider: () -> VoiceModelProfile

    init(
        renderer: any VoiceSpeechRendering = AppleVoiceSpeechRenderer(),
        profileProvider: @escaping () -> VoiceModelProfile
    ) {
        self.renderer = renderer
        self.profileProvider = profileProvider
    }

    func speak(_ text: String) async throws {
        try await renderer.speak(text, profile: profileProvider())
    }

    func stop() {
        renderer.stop()
    }
}
