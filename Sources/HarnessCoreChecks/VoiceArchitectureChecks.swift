import Foundation
import HarnessCore

enum VoiceArchitectureChecks {
    static func run() throws {
        let hash = String(repeating: "d", count: 64)
        let transcript = VoiceTranscript(
            text: "その案で直して",
            localeIdentifier: "ja-JP",
            stability: .finalized
        )
        let draft = VoiceActionAuthorityPolicy.decision(
            transcript: transcript,
            intent: .command,
            gesture: .none,
            action: .insertComposerDraft
        )
        let fileChange = VoiceActionAuthorityPolicy.decision(
            transcript: transcript,
            intent: .command,
            gesture: .userConfirmedTranscript,
            action: .modifyFiles
        )
        let conversation = VoiceActionAuthorityPolicy.decision(
            transcript: transcript,
            intent: .discussion,
            gesture: .userActivatedConversationMode,
            action: .submitConversation
        )
        let conversationFileChange = VoiceActionAuthorityPolicy.decision(
            transcript: transcript,
            intent: .command,
            gesture: .userActivatedConversationMode,
            action: .modifyFiles
        )
        var assembler = VoiceTranscriptAssembler()
        _ = assembler.receive("この画面", isFinal: false)
        _ = assembler.receive("この画面を直して", isFinal: true)
        let combinedDraft = VoiceDraftComposition.inserting(
            transcript,
            into: "既存の手入力"
        )
        let reference = VoiceReferenceDescriptor(
            displayName: "neutral.wav",
            source: .guidedRecording,
            durationMilliseconds: 10_000,
            audioContentHash: hash
        )
        let capsule = VoiceCapsuleManifest(
            displayName: "My Voice",
            kind: .ownedVoice,
            references: [reference],
            styleProfile: VoiceStyleProfile(languageCode: "ja-JP"),
            consent: VoiceConsentEvidence(
                status: .recordedLocally,
                consentRecordingContentHash: hash
            )
        )
        let importedPrivateCapsule = VoiceCapsuleManifest(
            displayName: "My Imported Voice",
            kind: .ownedVoice,
            references: [VoiceReferenceDescriptor(
                displayName: "reference.wav",
                source: .importedAudio,
                durationMilliseconds: 8_000,
                audioContentHash: hash
            )],
            styleProfile: VoiceStyleProfile(languageCode: "ja-JP"),
            consent: VoiceConsentEvidence(status: .userAttestedPrivateUse)
        )
        let engineCapsule = VoiceCapsuleManifest(
            displayName: "My Engine Voice",
            kind: .ownedVoice,
            references: [VoiceReferenceDescriptor(
                displayName: "reference.wav",
                source: .importedAudio,
                durationMilliseconds: 8_000,
                audioContentHash: hash,
                transcriptContentHash: hash
            )],
            styleProfile: VoiceStyleProfile(languageCode: "ja-JP"),
            consent: VoiceConsentEvidence(status: .userAttestedPrivateUse)
        )
        let engineRequest = VoiceEngineSynthesisRequest(
            text: "確認します。",
            languageCode: "ja-JP",
            capsuleID: engineCapsule.id,
            capsuleRevisionHash: hash,
            hasReferenceTranscript: true
        )
        let diagnostic = VoiceConversationMetrics(
            listeningPreparationMilliseconds: 400,
            responseMilliseconds: 3_500,
            outcome: .completed
        )
        let correction = VoiceBargeInPolicy.disposition(
            for: VoiceTranscript(
                text: "待って、そこは違う",
                localeIdentifier: "ja-JP",
                stability: .finalized
            ),
            spokenResponse: "このまま進めます"
        )
        let backchannel = VoiceBargeInPolicy.disposition(
            for: VoiceTranscript(
                text: "なるほど",
                localeIdentifier: "ja-JP",
                stability: .finalized
            ),
            spokenResponse: "次の案を説明します"
        )
        let includedVoices = VoiceModelCatalog.included
        let enginePreflight = VoiceEngineInstallationPolicy.preflight(
            isAppleSilicon: true,
            availableDiskBytes: 6_000_000_000
        )
        let engineProgress = VoiceEngineInstallationProgressParser.parse(
            #"{"phase":"verifying","status":"検証中","fraction":0.5}"#
        )
        let benchmark = VoiceEngineBenchmarkPolicy.report(
            engineIdentifier: VoiceEngineCatalog.qwen3TTSMLX.id,
            measurements: [
                VoiceEngineBenchmarkMeasurement(
                    sequence: 1,
                    elapsedMilliseconds: 3_200,
                    audioDurationMilliseconds: 4_000,
                    sampleRate: 24_000,
                    audioByteCount: 192_044
                ),
                VoiceEngineBenchmarkMeasurement(
                    sequence: 2,
                    elapsedMilliseconds: 2_000,
                    audioDurationMilliseconds: 4_000,
                    sampleRate: 24_000,
                    audioByteCount: 192_044
                )
            ]
        )

        try expect(
            draft.isAuthorized
                && !fileChange.isAuthorized
                && conversation.isAuthorized
                && !conversationFileChange.isAuthorized
                && assembler.combinedText == "この画面を直して"
                && combinedDraft == "既存の手入力\nその案で直して"
                && VoiceCapsulePolicy.validationError(for: capsule) == nil
                && VoiceCapsulePolicy.validationError(for: importedPrivateCapsule) == nil
                && VoiceCapsuleTranscriptPolicy.validationError(
                    for: "正確な見本です。",
                    allowsEmpty: false
                ) == nil
                && VoiceCapsuleTranscriptPolicy.validationError(
                    for: "  ",
                    allowsEmpty: false
                ) == .empty
                && VoiceEngineSynthesisPolicy.validationError(
                    for: engineRequest,
                    manifest: engineCapsule,
                    readiness: VoiceEngineReadiness(
                        engineIdentifier: VoiceEngineCatalog.qwen3TTSMLX.id,
                        phase: .ready
                    )
                ) == nil
                && VoiceInterruptionPolicy.effect(for: .activeProjectOperation)
                    == .requestCheckpointCancellation
                && VoiceSpokenSummaryPolicy.summary(for: "短く答えます。")
                    == "短く答えます。"
                && VoiceConversationMetricsFormatter.summary(for: diagnostic)
                    == "準備 0.4秒・回答 3.5秒"
                && VoiceTurnEndpointPolicy.gracePeriod(for: "えっと")
                    > VoiceTurnEndpointPolicy.gracePeriod(for: "以上")
                && correction == .interrupt
                && backchannel == .backchannel
                && VoiceConversationPromptGuidance.instruction(for: .voice)
                    .contains("1〜3文")
                && includedVoices.count == 3
                && includedVoices.allSatisfy(VoiceModelLibraryPolicy.isValid)
                && VoiceModelLibraryPolicy.resolvedSelection(
                    persistedID: "missing",
                    availableProfiles: includedVoices
                ) == VoiceModelCatalog.defaultProfileID
                && enginePreflight.canInstall
                && engineProgress?.phase == .verifying
                && engineProgress?.fraction == 0.5
                && benchmark?.assessment == .conversationCandidate,
            "Voice authority or capsule boundaries failed"
        )
        print("✓ Voice presets, capsules, synthesis, installation, and benchmark policy remain separate")
    }
}
