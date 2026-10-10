import HarnessCore
import Testing

struct VoiceTurnTakingPolicyTests {
    @Test func endpointWaitsLongerWhenTheSpeakerHoldsTheFloor() {
        #expect(VoiceTurnEndpointPolicy.gracePeriod(for: "それで、えっと") == .milliseconds(1_650))
        #expect(VoiceTurnEndpointPolicy.gracePeriod(for: "まず確認して、") == .milliseconds(1_450))
        #expect(VoiceTurnEndpointPolicy.gracePeriod(for: "これでお願い") == .milliseconds(450))
        #expect(VoiceTurnEndpointPolicy.gracePeriod(for: "分かりました。") == .milliseconds(650))
    }

    @Test func bargeInSeparatesEchoBackchannelsAndCorrections() {
        let spoken = "次の修正案を説明します"
        #expect(disposition("次の修正案を説明します", spoken: spoken) == .echo)
        #expect(disposition("うん", spoken: spoken) == .backchannel)
        #expect(disposition("待って、そこは違う", spoken: spoken) == .interrupt)
        #expect(disposition("別の案も見たい", spoken: spoken) == .interrupt)
    }

    @Test func voicePromptRequestsACompactSpokenReply() {
        let guidance = VoiceConversationPromptGuidance.instruction(
            for: .voice,
            voiceProfile: VoiceModelCatalog.included[0]
        )
        #expect(guidance.contains("1〜3文"))
        #expect(guidance.contains("見出し"))
        #expect(guidance.contains("Aegis"))
        #expect(guidance.contains("固有キャラクター"))
        #expect(VoiceConversationPromptGuidance.instruction(for: .screen).isEmpty)
    }

    @Test func transcriptFeedbackIsTrimmedAndBounded() {
        #expect(VoiceTranscriptFeedback.preview("  ここを直して  \n") == "ここを直して")
        let preview = VoiceTranscriptFeedback.preview(String(repeating: "あ", count: 60))
        #expect(preview.count == VoiceTranscriptFeedback.maximumPreviewCharacters)
        #expect(preview.hasSuffix("…"))
    }

    private func disposition(
        _ text: String,
        spoken: String
    ) -> VoiceBargeInDisposition {
        VoiceBargeInPolicy.disposition(
            for: VoiceTranscript(
                text: text,
                localeIdentifier: "ja-JP",
                stability: .finalized
            ),
            spokenResponse: spoken
        )
    }
}
