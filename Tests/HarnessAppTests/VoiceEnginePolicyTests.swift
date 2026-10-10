import Foundation
import HarnessCore
import Testing

struct VoiceEnginePolicyTests {
    @Test func installationNeedsSupportedHardwareAndSixGigabytesOfWorkingSpace() {
        let supported = VoiceEngineInstallationPolicy.preflight(
            isAppleSilicon: true,
            availableDiskBytes: 6_000_000_000
        )
        let shortOnSpace = VoiceEngineInstallationPolicy.preflight(
            isAppleSilicon: true,
            availableDiskBytes: 5_999_999_999
        )
        let unsupported = VoiceEngineInstallationPolicy.preflight(
            isAppleSilicon: false,
            availableDiskBytes: 20_000_000_000
        )

        #expect(supported.canInstall)
        #expect(!shortOnSpace.canInstall)
        #expect(!unsupported.canInstall)
    }

    @Test func installationProgressParsesBoundedWorkerEventsAndDownloadPercentages() {
        let verified = VoiceEngineInstallationProgressParser.parse(
            #"{"phase":"verifying","status":"モデル内容を検証しています","fraction":0.5}"#
        )
        let download = VoiceEngineInstallationProgressParser.parse(
            "Fetching files 72.5% |███████|"
        )

        #expect(verified?.phase == .verifying)
        #expect(verified?.fraction == 0.5)
        #expect(download?.phase == .downloadingModel)
        #expect(download?.fraction == 0.725)
        #expect(VoiceEngineInstallationProgressParser.parse("raw failure text") == nil)
    }

    @Test func transcriptPolicyTrimsInputAndKeepsCreationOptional() {
        #expect(VoiceCapsuleTranscriptPolicy.normalized("  見本です。\n") == "見本です。")
        #expect(
            VoiceCapsuleTranscriptPolicy.validationError(
                for: "  ",
                allowsEmpty: true
            ) == nil
        )
        #expect(
            VoiceCapsuleTranscriptPolicy.validationError(
                for: "  ",
                allowsEmpty: false
            ) == .empty
        )
        #expect(
            VoiceCapsuleTranscriptPolicy.validationError(
                for: String(repeating: "声", count: 4_001),
                allowsEmpty: false
            ) == .tooLong
        )
    }

    @Test func verifiedCapsuleWithTranscriptCanSynthesizeWhenEngineIsReady() {
        let manifest = makeManifest(hasTranscript: true)
        let request = makeRequest(manifest: manifest, hasTranscript: true)

        #expect(
            VoiceEngineSynthesisPolicy.validationError(
                for: request,
                manifest: manifest,
                readiness: readyState
            ) == nil
        )
    }

    @Test func synthesisRequiresReadyEngineAndExactReferenceTranscript() {
        let manifest = makeManifest(hasTranscript: false)
        let request = makeRequest(manifest: manifest, hasTranscript: false)

        #expect(
            VoiceEngineSynthesisPolicy.validationError(
                for: request,
                manifest: manifest,
                readiness: VoiceEngineReadiness(
                    engineIdentifier: VoiceEngineCatalog.qwen3TTSMLX.id,
                    phase: .modelMissing
                )
            ) == .engineNotReady
        )
        #expect(
            VoiceEngineSynthesisPolicy.validationError(
                for: request,
                manifest: manifest,
                readiness: readyState
            ) == .referenceTranscriptRequired
        )
    }

    @Test func synthesisRejectsOversizedTextAndMismatchedCapsule() {
        let manifest = makeManifest(hasTranscript: true)
        let oversized = VoiceEngineSynthesisRequest(
            text: String(repeating: "声", count: 1_201),
            languageCode: "ja-JP",
            capsuleID: manifest.id,
            capsuleRevisionHash: hash,
            hasReferenceTranscript: true
        )
        #expect(
            VoiceEngineSynthesisPolicy.validationError(
                for: oversized,
                manifest: manifest,
                readiness: readyState
            ) == .invalidText
        )

        let mismatched = VoiceEngineSynthesisRequest(
            text: "確認します。",
            languageCode: "ja-JP",
            capsuleID: UUID(),
            capsuleRevisionHash: hash,
            hasReferenceTranscript: true
        )
        #expect(
            VoiceEngineSynthesisPolicy.validationError(
                for: mismatched,
                manifest: manifest,
                readiness: readyState
            ) == .invalidCapsuleRevision
        )
    }

    private var readyState: VoiceEngineReadiness {
        VoiceEngineReadiness(
            engineIdentifier: VoiceEngineCatalog.qwen3TTSMLX.id,
            phase: .ready
        )
    }

    private var hash: String { String(repeating: "a", count: 64) }

    private func makeRequest(
        manifest: VoiceCapsuleManifest,
        hasTranscript: Bool
    ) -> VoiceEngineSynthesisRequest {
        VoiceEngineSynthesisRequest(
            text: "確認します。",
            languageCode: "ja-JP",
            capsuleID: manifest.id,
            capsuleRevisionHash: hash,
            hasReferenceTranscript: hasTranscript
        )
    }

    private func makeManifest(hasTranscript: Bool) -> VoiceCapsuleManifest {
        VoiceCapsuleManifest(
            displayName: "自分の声",
            kind: .ownedVoice,
            references: [VoiceReferenceDescriptor(
                displayName: "reference.wav",
                source: .importedAudio,
                durationMilliseconds: 8_000,
                audioContentHash: hash,
                transcriptContentHash: hasTranscript ? hash : nil
            )],
            styleProfile: VoiceStyleProfile(languageCode: "ja-JP"),
            consent: VoiceConsentEvidence(status: .userAttestedPrivateUse)
        )
    }
}
