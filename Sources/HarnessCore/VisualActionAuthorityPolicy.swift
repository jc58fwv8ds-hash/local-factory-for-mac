import Foundation

public enum VisualInstructionOrigin: String, Codable, Equatable, Sendable {
    case userText
    case imageContent
    case modelInterpretation
}

public enum VisualRequestedAction: String, Codable, Equatable, Sendable {
    case inspect
    case createEditPreview
    case modifyFiles
    case controlComputer
    case sendExternally
}

public struct VisualAuthorityDecision: Equatable, Sendable {
    public let isAuthorized: Bool
    public let reason: String

    public init(isAuthorized: Bool, reason: String) {
        self.isAuthorized = isAuthorized
        self.reason = reason
    }
}

public enum VisualActionAuthorityPolicy {
    /// Pixels and model interpretations are evidence, never authority for side effects.
    public static func decision(
        origin: VisualInstructionOrigin,
        action: VisualRequestedAction
    ) -> VisualAuthorityDecision {
        if action == .inspect {
            return VisualAuthorityDecision(
                isAuthorized: true,
                reason: "画像を読み取り専用で確認できます。"
            )
        }
        guard origin == .userText else {
            return VisualAuthorityDecision(
                isAuthorized: false,
                reason: "画像内の指示やAIの解釈だけでは、この操作を許可しません。"
            )
        }
        return VisualAuthorityDecision(
            isAuthorized: action == .createEditPreview,
            reason: action == .createEditPreview
                ? "ユーザーの本文に基づき、元画像を変えない下書きを作れます。"
                : "ファイル変更・Computer操作・外部送信には専用の確認手順が必要です。"
        )
    }
}
