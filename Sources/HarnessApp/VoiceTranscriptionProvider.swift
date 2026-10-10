import Foundation
import HarnessCore

enum VoiceTranscriptionAvailability: Equatable, Sendable {
    case available
    case requiresMacOS26
}

enum VoiceTranscriptionStatus: Equatable, Sendable {
    case requestingMicrophone
    case preparingLanguageModel
    case downloadingLanguageModel
    case recording
    case finalizing
}

@MainActor
protocol VoiceTranscriptionProviding: AnyObject {
    var availability: VoiceTranscriptionAvailability { get }
    var microphoneAuthorization: VoiceMicrophoneAuthorization { get }

    func start(
        localeIdentifier: String,
        onTranscript: @escaping @MainActor @Sendable (VoiceTranscript) -> Void,
        onActivity: @escaping @MainActor @Sendable (VoiceConversationActivity) -> Void,
        onStatus: @escaping @MainActor @Sendable (VoiceTranscriptionStatus) -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async throws

    func finish() async throws
    func cancel() async
}

@MainActor
enum VoiceTranscriptionProviderFactory {
    static func makeSystemProvider() -> any VoiceTranscriptionProviding {
        if #available(macOS 26.0, *) {
            AppleSpeechTranscriptionProvider()
        } else {
            UnsupportedVoiceTranscriptionProvider()
        }
    }
}

@MainActor
private final class UnsupportedVoiceTranscriptionProvider: VoiceTranscriptionProviding {
    let availability = VoiceTranscriptionAvailability.requiresMacOS26
    let microphoneAuthorization = VoiceMicrophoneAuthorization.unavailable

    func start(
        localeIdentifier: String,
        onTranscript: @escaping @MainActor @Sendable (VoiceTranscript) -> Void,
        onActivity: @escaping @MainActor @Sendable (VoiceConversationActivity) -> Void,
        onStatus: @escaping @MainActor @Sendable (VoiceTranscriptionStatus) -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        throw VoiceTranscriptionError.unsupportedSystem
    }

    func finish() async throws {}
    func cancel() async {}
}

enum VoiceTranscriptionError: LocalizedError, Equatable {
    case unsupportedSystem
    case microphoneDenied
    case microphoneRestricted
    case microphoneAuthorizationUnavailable
    case localeUnsupported
    case languageModelUnavailable
    case audioInputUnavailable
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            "端末内の音声入力はmacOS 26以降で使えます。文字入力はそのまま使えます。"
        case .microphoneDenied:
            "マイクを使えません。システム設定の「プライバシーとセキュリティ」でLocal Factoryのマイクを許可してね。"
        case .microphoneRestricted:
            "このMacではマイクの使用が制限されています。スクリーンタイムや管理設定を確認してね。"
        case .microphoneAuthorizationUnavailable:
            "マイクの使用状態を確認できませんでした。Macを再起動して、もう一度試してね。"
        case .localeUnsupported:
            "この言語の端末内文字起こしには、まだ対応していません。"
        case .languageModelUnavailable:
            "音声入力用の言語データを準備できませんでした。通信を確認して、もう一度試してね。"
        case .audioInputUnavailable:
            "Macのマイクから音声を読み取れませんでした。入力機器を確認してね。"
        case .recognitionFailed(let detail):
            "音声を文字にできませんでした：\(detail)"
        }
    }
}
