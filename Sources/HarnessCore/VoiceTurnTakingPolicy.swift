import Foundation

public enum ConversationDeliveryMode: Equatable, Sendable {
    case screen
    case voice
}

public enum VoiceConversationPromptGuidance {
    public static func instruction(
        for mode: ConversationDeliveryMode,
        voiceProfile: VoiceModelProfile? = nil
    ) -> String {
        guard mode == .voice else { return "" }
        let profileGuidance: String
        if let voiceProfile, voiceProfile.source == .includedPreset {
            profileGuidance = """

            選択中の会話プリセットは\(voiceProfile.displayName)です。
            会話の調子: \(voiceProfile.stylePrompt)
            映画・作品の固有キャラクターや実在人物の声・人格を模倣せず、Harness自身として話してください。
            """
        } else {
            profileGuidance = ""
        }
        return """
        今は音声会話です。最初の1文で直接答え、通常は1〜3文の自然な話し言葉にしてください。
        見出し、箇条書き、Markdown、前置きの言い換えを避け、必要なら最後に確認を1つだけ聞いてください。
        長い手順や検査結果は画面で読めるため、音声では要点と次の一歩を優先してください。
        \(profileGuidance)
        """
    }
}

public enum VoiceTurnEndpointPolicy {
    public static func gracePeriod(for transcript: String) -> Duration {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .milliseconds(1_250) }
        let compact = text.lowercased()

        if explicitTurnEndings.contains(where: compact.hasSuffix) {
            return .milliseconds(450)
        }
        if floorHoldingEndings.contains(where: compact.hasSuffix) {
            return .milliseconds(1_650)
        }
        if text.last.map({ "、,…".contains($0) }) == true {
            return .milliseconds(1_450)
        }
        if text.last.map({ "。！？!?".contains($0) }) == true {
            return .milliseconds(650)
        }
        return .milliseconds(1_050)
    }

    private static let explicitTurnEndings = [
        "以上", "送って", "答えて", "教えて", "お願い", "どう思う", "どうかな",
        "that's all", "go ahead", "please answer"
    ]

    private static let floorHoldingEndings = [
        "えっと", "えーと", "あの", "その", "なんか", "というか", "けど", "けれど",
        "ので", "から", "それで", "あと", "例えば", "and", "but", "because", "so", "um", "uh"
    ]
}

public enum VoiceBargeInDisposition: Equatable, Sendable {
    case echo
    case backchannel
    case interrupt
}

public enum VoiceBargeInPolicy {
    public static func disposition(
        for transcript: VoiceTranscript,
        spokenResponse: String
    ) -> VoiceBargeInDisposition {
        let candidate = normalized(transcript.text)
        guard candidate.count >= 2 else { return .backchannel }
        let response = normalized(spokenResponse)
        if !response.isEmpty, response.contains(candidate) {
            return .echo
        }
        if backchannels.contains(candidate) {
            return .backchannel
        }
        if interruptionCues.contains(where: candidate.hasPrefix) {
            return .interrupt
        }
        if transcript.stability == .finalized, candidate.count >= 4 {
            return .interrupt
        }
        return candidate.count >= 6 ? .interrupt : .backchannel
    }

    private static let backchannels: Set<String> = [
        "うん", "はい", "そう", "なるほど", "ふんふん", "へえ", "ok", "okay", "right"
    ]

    private static let interruptionCues = [
        "待って", "ちょっと待って", "ストップ", "違う", "いや", "それじゃなくて",
        "訂正", "やっぱり", "ごめん", "wait", "stop", "no", "actually"
    ]

    private static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0.value > 0x7F
        }.map(String.init).joined()
    }
}
