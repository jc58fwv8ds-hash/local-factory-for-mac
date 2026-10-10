@preconcurrency import AVFAudio
import HarnessCore

struct SystemVoiceOption: Identifiable, Equatable, Sendable {
    enum Quality: Int, Comparable, Sendable {
        case standard
        case enhanced
        case premium

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let name: String
    let languageCode: String
    let quality: Quality

    var qualityLabel: String {
        switch quality {
        case .standard: "標準"
        case .enhanced: "高品質"
        case .premium: "最高品質"
        }
    }
}

@MainActor
protocol SystemVoiceCatalogProviding {
    func installedVoices() -> [SystemVoiceOption]
    func resolveVoice(for profile: VoiceModelProfile) -> AVSpeechSynthesisVoice?
}

@MainActor
struct AppleSystemVoiceCatalog: SystemVoiceCatalogProviding {
    func installedVoices() -> [SystemVoiceOption] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            SystemVoiceOption(
                id: voice.identifier,
                name: voice.name,
                languageCode: voice.language,
                quality: quality(of: voice)
            )
        }.sorted { lhs, rhs in
            let lhsJapanese = lhs.languageCode.hasPrefix("ja")
            let rhsJapanese = rhs.languageCode.hasPrefix("ja")
            if lhsJapanese != rhsJapanese { return lhsJapanese }
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            if lhs.languageCode != rhs.languageCode {
                return lhs.languageCode.localizedStandardCompare(rhs.languageCode) == .orderedAscending
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func resolveVoice(for profile: VoiceModelProfile) -> AVSpeechSynthesisVoice? {
        if let identifier = profile.engineVoiceIdentifier,
           let exact = AVSpeechSynthesisVoice(identifier: identifier) {
            return exact
        }
        let matchingLanguage = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.caseInsensitiveCompare(profile.languageCode) == .orderedSame
        }
        if let preferred = profile.preferredSystemVoiceName,
           let named = matchingLanguage.first(where: {
               $0.name.caseInsensitiveCompare(preferred) == .orderedSame
           }) {
            return named
        }
        return matchingLanguage.max { quality(of: $0) < quality(of: $1) }
            ?? AVSpeechSynthesisVoice(language: profile.languageCode)
    }

    private func quality(of voice: AVSpeechSynthesisVoice) -> SystemVoiceOption.Quality {
        switch voice.quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .standard
        }
    }
}
