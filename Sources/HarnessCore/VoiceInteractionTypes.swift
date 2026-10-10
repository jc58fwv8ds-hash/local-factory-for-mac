import Foundation

public enum VoiceInputMode: String, Codable, CaseIterable, Equatable, Sendable {
    case pushToTalk
    case conversation
    case wakeWord
}

public enum VoiceInteractionPhase: String, Codable, Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case reviewingTranscript
    case thinking
    case speaking
    case interrupted
    case failed
}

public enum VoiceIntent: String, Codable, CaseIterable, Equatable, Sendable {
    case discussion
    case idea
    case proposal
    case command
    case cancel
    case approve
    case status
}

public enum VoiceTranscriptStability: String, Codable, Equatable, Sendable {
    case volatile
    case finalized
    case userCorrected
}

/// Text is the authoritative handoff between speech recognition and Harness.
/// Raw audio remains transient unless the user explicitly chooses to save it.
public struct VoiceTranscript: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let text: String
    public let localeIdentifier: String
    public let stability: VoiceTranscriptStability

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        text: String,
        localeIdentifier: String,
        stability: VoiceTranscriptStability
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.localeIdentifier = localeIdentifier
        self.stability = stability
    }
}

public enum VoiceInterruptionTarget: String, Codable, Equatable, Sendable {
    case microphoneCapture
    case spokenResponse
    case activeProjectOperation
}

public enum VoiceInterruptionEffect: String, Codable, Equatable, Sendable {
    case stopCapture
    case stopPlayback
    case requestCheckpointCancellation
}

public enum VoiceInterruptionPolicy {
    public static func effect(for target: VoiceInterruptionTarget) -> VoiceInterruptionEffect {
        switch target {
        case .microphoneCapture:
            .stopCapture
        case .spokenResponse:
            .stopPlayback
        case .activeProjectOperation:
            .requestCheckpointCancellation
        }
    }
}

public struct VoiceResponsePresentation: Codable, Equatable, Sendable {
    public let spokenSummary: String
    public let screenDetail: String

    public init(spokenSummary: String, screenDetail: String) {
        self.spokenSummary = spokenSummary
        self.screenDetail = screenDetail
    }
}
