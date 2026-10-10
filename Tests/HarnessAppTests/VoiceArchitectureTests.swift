import Foundation
import HarnessCore
import Testing

struct VoiceArchitectureTests {
    private let hash = String(repeating: "c", count: 64)

    @Test func volatileSpeechCanNeverSubmitOrModifyAnything() {
        let transcript = VoiceTranscript(
            text: "じゃあそれで直して",
            localeIdentifier: "ja-JP",
            stability: .volatile
        )

        #expect(!VoiceActionAuthorityPolicy.decision(
            transcript: transcript,
            intent: .command,
            gesture: .userPressedSubmit,
            action: .submitConversation
        ).isAuthorized)
        #expect(!VoiceActionAuthorityPolicy.decision(
            transcript: transcript,
            intent: .command,
            gesture: .userPressedSubmit,
            action: .modifyFiles
        ).isAuthorized)
    }

    @Test func finalizedTranscriptBecomesAnEditableDraftBeforeSubmission() {
        let transcript = VoiceTranscript(
            text: "この画面をもう少し見やすくして",
            localeIdentifier: "ja-JP",
            stability: .finalized
        )

        #expect(VoiceActionAuthorityPolicy.decision(
            transcript: transcript,
            intent: .command,
            gesture: .none,
            action: .insertComposerDraft
        ).isAuthorized)
        #expect(!VoiceActionAuthorityPolicy.decision(
            transcript: transcript,
            intent: .command,
            gesture: .none,
            action: .submitConversation
        ).isAuthorized)
        #expect(VoiceActionAuthorityPolicy.decision(
            transcript: transcript,
            intent: .command,
            gesture: .userConfirmedTranscript,
            action: .submitConversation
        ).isAuthorized)
    }

    @Test func spokenApprovalCannotBypassTheExistingPermissionFlow() {
        let transcript = VoiceTranscript(
            text: "うん、それで実行して",
            localeIdentifier: "ja-JP",
            stability: .userCorrected
        )

        for action in [
            VoiceRequestedAction.modifyFiles,
            .controlComputer,
            .approvePendingOperation,
            .sendExternally
        ] {
            #expect(!VoiceActionAuthorityPolicy.decision(
                transcript: transcript,
                intent: .approve,
                gesture: .userConfirmedTranscript,
                action: action
            ).isAuthorized)
        }
    }

    @Test func conversationModeCanSubmitTextButStillCannotGrantSideEffects() {
        let transcript = VoiceTranscript(
            text: "この案の良いところを教えて",
            localeIdentifier: "ja-JP",
            stability: .finalized
        )
        #expect(VoiceActionAuthorityPolicy.decision(
            transcript: transcript,
            intent: .discussion,
            gesture: .userActivatedConversationMode,
            action: .submitConversation
        ).isAuthorized)
        #expect(!VoiceActionAuthorityPolicy.decision(
            transcript: transcript,
            intent: .approve,
            gesture: .userActivatedConversationMode,
            action: .modifyFiles
        ).isAuthorized)
    }

    @Test func spokenSummaryStaysShortAndKeepsTheFullAnswerOnScreen() {
        let long = String(repeating: "これは詳しい説明です。", count: 30)
        let summary = VoiceSpokenSummaryPolicy.summary(for: long)
        #expect(summary.count <= VoiceSpokenSummaryPolicy.maximumCharacters + 18)
        #expect(summary.contains("続きは画面"))
        #expect(VoiceSpokenSummaryPolicy.summary(for: "短い答えです。") == "短い答えです。")
    }

    @Test func voiceDiagnosticsContainTimingButNoTranscriptOrAudio() {
        let metrics = VoiceConversationMetrics(
            listeningPreparationMilliseconds: 400,
            turnCompletionMilliseconds: 1_000,
            responseMilliseconds: 3_500,
            playbackMilliseconds: 1_500,
            spokenCharacterCount: 18,
            outcome: .interrupted
        )
        let summary = VoiceConversationMetricsFormatter.summary(for: metrics)
        #expect(summary == "準備 0.4秒・確定 1.0秒・回答 3.5秒・音声 1.5秒（読み上げを中断）")
        #expect(!summary.contains("音声本文"))
    }

    @Test func partialResultsAreReplacedAndFinalResultsAccumulateWithoutDuplication() {
        var assembler = VoiceTranscriptAssembler()
        #expect(assembler.receive("この画面", isFinal: false) == "この画面")
        #expect(assembler.receive("この画面を", isFinal: false) == "この画面を")
        #expect(assembler.receive("この画面を見やすくして", isFinal: true) == "この画面を見やすくして")
        #expect(assembler.receive(" please", isFinal: true) == "この画面を見やすくしてplease")
        #expect(assembler.volatileText.isEmpty)
    }

    @Test func voiceDraftPreservesAnythingTheUserAlreadyTyped() {
        let transcript = VoiceTranscript(
            text: "あと、説明は短めでね",
            localeIdentifier: "ja-JP",
            stability: .finalized
        )
        #expect(
            VoiceDraftComposition.inserting(transcript, into: "続けよう")
                == "続けよう\nあと、説明は短めでね"
        )
        #expect(VoiceDraftComposition.inserting(transcript, into: "") == transcript.text)
    }

    @Test func interruptionStopsSpeechButOnlyRequestsSafeOperationCancellation() {
        #expect(VoiceInterruptionPolicy.effect(for: .spokenResponse) == .stopPlayback)
        #expect(
            VoiceInterruptionPolicy.effect(for: .activeProjectOperation)
                == .requestCheckpointCancellation
        )
    }

    @Test func voiceCapsuleManifestIsPortableAndEngineIndependent() throws {
        let manifest = ownedManifest()
        let encoded = try JSONEncoder().encode(manifest)
        let json = String(decoding: encoded, as: UTF8.self).lowercased()

        #expect(VoiceCapsulePolicy.validationError(for: manifest) == nil)
        #expect(!json.contains("embedding"))
        #expect(!json.contains("engine"))
        #expect(!json.contains("qwen"))

        let cache = VoiceEngineCacheDescriptor(
            engineIdentifier: "future-tts",
            capsuleRevisionHash: hash
        )
        #expect(cache.isDisposable)
    }

    @Test func importedVoiceRequiresConsentAndVerifiedExport() {
        var manifest = ownedManifest(consent: .init(status: .missing))
        #expect(VoiceCapsulePolicy.validationError(for: manifest) == .missingConsent)

        manifest = ownedManifest(consent: .init(status: .userAttestedPrivateUse))
        #expect(VoiceCapsulePolicy.validationError(for: manifest) == nil)

        manifest = ownedManifest(
            consent: .init(status: .recordedLocally, consentRecordingContentHash: hash),
            usageScope: .exportAllowed
        )
        #expect(
            VoiceCapsulePolicy.validationError(for: manifest)
                == .exportNeedsVerifiedConsent
        )
    }

    private func ownedManifest(
        consent: VoiceConsentEvidence? = nil,
        usageScope: VoiceUsageScope = .privateOnDevice
    ) -> VoiceCapsuleManifest {
        let reference = VoiceReferenceDescriptor(
            displayName: "neutral.wav",
            source: .guidedRecording,
            durationMilliseconds: 12_000,
            audioContentHash: hash,
            transcriptContentHash: hash,
            alignmentContentHash: hash
        )
        return VoiceCapsuleManifest(
            displayName: "My Voice",
            kind: .ownedVoice,
            references: [reference],
            styleProfile: VoiceStyleProfile(languageCode: "ja-JP"),
            consent: consent ?? VoiceConsentEvidence(
                status: .recordedLocally,
                consentRecordingContentHash: hash
            ),
            usageScope: usageScope
        )
    }
}
