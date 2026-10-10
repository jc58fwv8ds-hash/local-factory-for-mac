import Foundation
import HarnessCore

@MainActor
protocol VoiceResponseSpeaking: AnyObject {
    func speak(_ text: String) async throws
    func stop()
}

@MainActor
enum VoiceResponseSpeakerFactory {
    static func makeSystemSpeaker(
        profileProvider: @escaping () -> VoiceModelProfile
    ) -> any VoiceResponseSpeaking {
        AppleVoiceResponseSpeaker(profileProvider: profileProvider)
    }
}

enum VoiceResponseSpeechError: LocalizedError {
    case voiceUnavailable

    var errorDescription: String? {
        "Macの日本語音声を使えませんでした。返答は画面で確認できます。"
    }
}
