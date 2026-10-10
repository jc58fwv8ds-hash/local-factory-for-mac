import Foundation

public enum VoiceConversationTurnOutcome: String, Equatable, Sendable {
    case completed
    case interrupted
    case playbackFailed
    case submissionPaused
    case responseFailed
    case transcriptionFailed
}

public struct VoiceConversationMetrics: Equatable, Sendable {
    public let listeningPreparationMilliseconds: Int?
    public let turnCompletionMilliseconds: Int?
    public let responseMilliseconds: Int?
    public let playbackMilliseconds: Int?
    public let spokenCharacterCount: Int
    public let outcome: VoiceConversationTurnOutcome

    public init(
        listeningPreparationMilliseconds: Int? = nil,
        turnCompletionMilliseconds: Int? = nil,
        responseMilliseconds: Int? = nil,
        playbackMilliseconds: Int? = nil,
        spokenCharacterCount: Int = 0,
        outcome: VoiceConversationTurnOutcome
    ) {
        self.listeningPreparationMilliseconds = listeningPreparationMilliseconds
        self.turnCompletionMilliseconds = turnCompletionMilliseconds
        self.responseMilliseconds = responseMilliseconds
        self.playbackMilliseconds = playbackMilliseconds
        self.spokenCharacterCount = spokenCharacterCount
        self.outcome = outcome
    }
}

public enum VoiceConversationMetricsFormatter {
    public static func summary(for metrics: VoiceConversationMetrics) -> String {
        var parts: [String] = []
        append("準備", metrics.listeningPreparationMilliseconds, to: &parts)
        append("確定", metrics.turnCompletionMilliseconds, to: &parts)
        append("回答", metrics.responseMilliseconds, to: &parts)
        append("音声", metrics.playbackMilliseconds, to: &parts)
        let timing = parts.isEmpty ? "計測途中" : parts.joined(separator: "・")
        switch metrics.outcome {
        case .completed:
            return timing
        case .interrupted:
            return timing + "（読み上げを中断）"
        case .playbackFailed:
            return timing + "（読み上げ失敗）"
        case .submissionPaused:
            return timing + "（送信保留）"
        case .responseFailed:
            return timing + "（回答失敗）"
        case .transcriptionFailed:
            return timing + "（聞き取り失敗）"
        }
    }

    private static func append(_ label: String, _ milliseconds: Int?, to parts: inout [String]) {
        guard let milliseconds else { return }
        parts.append(String(format: "%@ %.1f秒", label, Double(milliseconds) / 1_000))
    }
}
