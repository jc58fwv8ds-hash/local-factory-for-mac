import Foundation

public enum VoiceCapsuleKind: String, Codable, Equatable, Sendable {
    case preset
    case ownedVoice
    case licensedVoice
}

public enum VoiceReferenceSource: String, Codable, Equatable, Sendable {
    case guidedRecording
    case importedAudio
    case importedVideoSegment
}

public enum VoiceConsentStatus: String, Codable, Equatable, Sendable {
    case notRequiredForPreset
    case recordedLocally
    case userAttestedPrivateUse
    case externallyVerified
    case missing
}

public enum VoiceUsageScope: String, Codable, Equatable, Sendable {
    case privateOnDevice
    case exportAllowed
}

/// Content-free metadata. Audio, transcripts, and alignments live in a managed asset store.
public struct VoiceReferenceDescriptor: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let source: VoiceReferenceSource
    public let durationMilliseconds: Int
    public let audioContentHash: String
    public let transcriptContentHash: String?
    public let alignmentContentHash: String?

    public init(
        id: UUID = UUID(),
        displayName: String,
        source: VoiceReferenceSource,
        durationMilliseconds: Int,
        audioContentHash: String,
        transcriptContentHash: String? = nil,
        alignmentContentHash: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.durationMilliseconds = durationMilliseconds
        self.audioContentHash = audioContentHash
        self.transcriptContentHash = transcriptContentHash
        self.alignmentContentHash = alignmentContentHash
    }
}

public struct VoiceConsentEvidence: Codable, Equatable, Sendable {
    public let status: VoiceConsentStatus
    public let consentRecordingContentHash: String?
    public let speakerMatchVerified: Bool

    public init(
        status: VoiceConsentStatus,
        consentRecordingContentHash: String? = nil,
        speakerMatchVerified: Bool = false
    ) {
        self.status = status
        self.consentRecordingContentHash = consentRecordingContentHash
        self.speakerMatchVerified = speakerMatchVerified
    }
}

public struct VoiceStyleProfile: Codable, Equatable, Sendable {
    public let style: String
    public let emotion: String
    public let languageCode: String
    public let speakingRate: Double

    public init(
        style: String = "normal",
        emotion: String = "neutral",
        languageCode: String,
        speakingRate: Double = 1
    ) {
        self.style = style
        self.emotion = emotion
        self.languageCode = languageCode
        self.speakingRate = speakingRate
    }
}

/// Stable, model-independent identity metadata for a portable voice asset.
public struct VoiceCapsuleManifest: Identifiable, Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let id: UUID
    public let schemaVersion: Int
    public let createdAt: Date
    public let displayName: String
    public let kind: VoiceCapsuleKind
    public let references: [VoiceReferenceDescriptor]
    public let styleProfile: VoiceStyleProfile
    public let consent: VoiceConsentEvidence
    public let usageScope: VoiceUsageScope
    public let syntheticDisclosureEnabled: Bool

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = Self.currentSchemaVersion,
        createdAt: Date = .now,
        displayName: String,
        kind: VoiceCapsuleKind,
        references: [VoiceReferenceDescriptor],
        styleProfile: VoiceStyleProfile,
        consent: VoiceConsentEvidence,
        usageScope: VoiceUsageScope = .privateOnDevice,
        syntheticDisclosureEnabled: Bool = true
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.displayName = displayName
        self.kind = kind
        self.references = references
        self.styleProfile = styleProfile
        self.consent = consent
        self.usageScope = usageScope
        self.syntheticDisclosureEnabled = syntheticDisclosureEnabled
    }
}

/// Engine-specific derived data. It is deliberately excluded from VoiceCapsuleManifest.
public struct VoiceEngineCacheDescriptor: Codable, Equatable, Sendable {
    public let engineIdentifier: String
    public let capsuleRevisionHash: String
    public let createdAt: Date

    public init(engineIdentifier: String, capsuleRevisionHash: String, createdAt: Date = .now) {
        self.engineIdentifier = engineIdentifier
        self.capsuleRevisionHash = capsuleRevisionHash
        self.createdAt = createdAt
    }

    public var isDisposable: Bool { true }
}
