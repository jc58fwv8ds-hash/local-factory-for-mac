import Foundation

public enum VoiceModelSource: String, Codable, Equatable, Sendable {
    case includedPreset
    case systemVoice
    case localModel
}

/// A selectable speaking voice. Model weights and speaker embeddings never live here.
public struct VoiceModelProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let source: VoiceModelSource
    public let engineIdentifier: String
    public let engineVoiceIdentifier: String?
    public let preferredSystemVoiceName: String?
    public let languageCode: String
    public let speakingRate: Double
    public let pitchMultiplier: Double
    public let stylePrompt: String

    public init(
        id: String,
        displayName: String,
        summary: String,
        source: VoiceModelSource,
        engineIdentifier: String,
        engineVoiceIdentifier: String? = nil,
        preferredSystemVoiceName: String? = nil,
        languageCode: String,
        speakingRate: Double = 1,
        pitchMultiplier: Double = 1,
        stylePrompt: String
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.source = source
        self.engineIdentifier = engineIdentifier
        self.engineVoiceIdentifier = engineVoiceIdentifier
        self.preferredSystemVoiceName = preferredSystemVoiceName
        self.languageCode = languageCode
        self.speakingRate = speakingRate
        self.pitchMultiplier = pitchMultiplier
        self.stylePrompt = stylePrompt
    }

    public var isRemovable: Bool { source == .systemVoice }
}

public enum VoiceModelCatalog {
    public static let defaultProfileID = "included.aegis"
    public static let systemEngineIdentifier = "apple.avspeech"

    public static let included: [VoiceModelProfile] = [
        VoiceModelProfile(
            id: defaultProfileID,
            displayName: "Aegis",
            summary: "落ち着いて先回りし、必要なときだけ少し機知を添える",
            source: .includedPreset,
            engineIdentifier: systemEngineIdentifier,
            preferredSystemVoiceName: "Reed",
            languageCode: "ja-JP",
            speakingRate: 0.96,
            pitchMultiplier: 0.94,
            stylePrompt: "結論を先に伝え、状況から次の一手を静かに提案する。機知は短い一言までにする。"
        ),
        VoiceModelProfile(
            id: "included.lumen",
            displayName: "Lumen",
            summary: "やわらかく明晰で、アイデアを一緒に整理する",
            source: .includedPreset,
            engineIdentifier: systemEngineIdentifier,
            preferredSystemVoiceName: "Sandy",
            languageCode: "ja-JP",
            speakingRate: 0.94,
            pitchMultiplier: 1.02,
            stylePrompt: "やわらかく明晰に話し、アイデアと不確定点を一緒に整理する。"
        ),
        VoiceModelProfile(
            id: "included.pulse",
            displayName: "Pulse",
            summary: "短く軽快で、作業中の往復をテンポよく進める",
            source: .includedPreset,
            engineIdentifier: systemEngineIdentifier,
            preferredSystemVoiceName: "Eddy",
            languageCode: "ja-JP",
            speakingRate: 1.08,
            pitchMultiplier: 1,
            stylePrompt: "短い文で軽快に話し、作業を止めず次の操作へつなげる。"
        )
    ]

    public static func systemProfile(
        identifier: String,
        name: String,
        languageCode: String
    ) -> VoiceModelProfile {
        VoiceModelProfile(
            id: "system.\(identifier)",
            displayName: name,
            summary: "Macにインストール済みの\(languageCode)音声",
            source: .systemVoice,
            engineIdentifier: systemEngineIdentifier,
            engineVoiceIdentifier: identifier,
            preferredSystemVoiceName: name,
            languageCode: languageCode,
            stylePrompt: "自然で簡潔に話し、声の持ち主や人物像を推測しない。"
        )
    }
}

public enum VoiceModelLibraryPolicy {
    public static let maximumAddedVoices = 24

    public static func isValid(_ profile: VoiceModelProfile) -> Bool {
        bounded(profile.id, maximum: 180)
            && bounded(profile.displayName, maximum: 80)
            && bounded(profile.summary, maximum: 240)
            && bounded(profile.engineIdentifier, maximum: 120)
            && bounded(profile.languageCode, maximum: 24)
            && bounded(profile.stylePrompt, maximum: 500)
            && profile.speakingRate >= 0.5 && profile.speakingRate <= 1.5
            && profile.pitchMultiplier >= 0.5 && profile.pitchMultiplier <= 2
            && (profile.source == .includedPreset
                || bounded(profile.engineVoiceIdentifier ?? "", maximum: 240))
    }

    public static func boundedAddedIdentifiers(_ identifiers: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for identifier in identifiers {
            let cleaned = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard bounded(cleaned, maximum: 240), seen.insert(cleaned).inserted else {
                continue
            }
            result.append(cleaned)
            if result.count == maximumAddedVoices { break }
        }
        return result
    }

    public static func resolvedSelection(
        persistedID: String?,
        availableProfiles: [VoiceModelProfile]
    ) -> String {
        if let persistedID,
           availableProfiles.contains(where: { $0.id == persistedID }) {
            return persistedID
        }
        return availableProfiles.first?.id ?? VoiceModelCatalog.defaultProfileID
    }

    private static func bounded(_ value: String, maximum: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maximum
            && !trimmed.contains("\n") && !trimmed.contains("\r")
    }
}
