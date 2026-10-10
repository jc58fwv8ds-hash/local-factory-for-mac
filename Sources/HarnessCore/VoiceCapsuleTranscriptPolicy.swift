import Foundation

public enum VoiceCapsuleTranscriptPolicyError: LocalizedError, Equatable, Sendable {
    case empty
    case tooLong

    public var errorDescription: String? {
        switch self {
        case .empty:
            "見本音声で話している内容を入力してください。"
        case .tooLong:
            "文字起こしは4,000文字以内にしてください。"
        }
    }
}

public enum VoiceCapsuleTranscriptPolicy {
    public static let maximumCharacters = 4_000

    public static func normalized(_ transcript: String) -> String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func validationError(
        for transcript: String,
        allowsEmpty: Bool
    ) -> VoiceCapsuleTranscriptPolicyError? {
        let normalized = normalized(transcript)
        if normalized.isEmpty, !allowsEmpty { return .empty }
        if normalized.count > maximumCharacters { return .tooLong }
        return nil
    }
}
