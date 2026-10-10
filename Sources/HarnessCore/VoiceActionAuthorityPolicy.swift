import Foundation

public enum VoiceSubmissionGesture: String, Codable, Equatable, Sendable {
    case none
    case userPressedSubmit
    case userConfirmedTranscript
    case userActivatedConversationMode
}

public enum VoiceRequestedAction: String, Codable, Equatable, Sendable {
    case insertComposerDraft
    case submitConversation
    case modifyFiles
    case controlComputer
    case approvePendingOperation
    case sendExternally
}

public struct VoiceAuthorityDecision: Equatable, Sendable {
    public let isAuthorized: Bool
    public let reason: String

    public init(isAuthorized: Bool, reason: String) {
        self.isAuthorized = isAuthorized
        self.reason = reason
    }
}

public enum VoiceActionAuthorityPolicy {
    /// A transcript can propose an instruction, but cannot grant side-effect authority.
    public static func decision(
        transcript: VoiceTranscript,
        intent: VoiceIntent,
        gesture: VoiceSubmissionGesture,
        action: VoiceRequestedAction
    ) -> VoiceAuthorityDecision {
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return VoiceAuthorityDecision(
                isAuthorized: false,
                reason: "聞き取った内容が空なので、操作しません。"
            )
        }
        guard transcript.stability != .volatile else {
            return VoiceAuthorityDecision(
                isAuthorized: false,
                reason: "聞き取り途中の文章は実行せず、確定するまで下書きとして表示します。"
            )
        }

        switch action {
        case .insertComposerDraft:
            return VoiceAuthorityDecision(
                isAuthorized: true,
                reason: "確定した聞き取り結果を、編集できる下書きとして表示します。"
            )
        case .submitConversation:
            let submitted = gesture == .userPressedSubmit
                || gesture == .userConfirmedTranscript
                || gesture == .userActivatedConversationMode
            return VoiceAuthorityDecision(
                isAuthorized: submitted,
                reason: submitted
                    ? "ユーザーが画面上で確定したため、通常の会話経路へ渡します。"
                    : "音声だけでは送信せず、画面上での確定を待ちます。"
            )
        case .modifyFiles, .controlComputer, .approvePendingOperation, .sendExternally:
            return VoiceAuthorityDecision(
                isAuthorized: false,
                reason: intent == .approve
                    ? "音声の承認だけでは許可せず、既存の確認画面を使います。"
                    : "音声は指示候補を作れますが、この操作には通常の権限確認が必要です。"
            )
        }
    }
}
