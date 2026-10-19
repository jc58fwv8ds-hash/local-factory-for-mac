import Foundation

public enum VoiceEngineReadinessPhase: String, Codable, Equatable, Sendable {
    case unsupportedHardware
    case notInstalled
    case runtimeMissing
    case modelMissing
    case ready
    case failed
}

public struct VoiceEngineReadiness: Codable, Equatable, Sendable {
    public let engineIdentifier: String
    public let phase: VoiceEngineReadinessPhase

    public init(engineIdentifier: String, phase: VoiceEngineReadinessPhase) {
        self.engineIdentifier = engineIdentifier
        self.phase = phase
    }

    public var canSynthesize: Bool { phase == .ready }
}

public struct VoiceEngineCatalogEntry: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let runtimeName: String
    public let modelIdentifier: String
    public let estimatedDownloadGB: Double
    public let requiresAppleSilicon: Bool

    public init(
        id: String,
        displayName: String,
        runtimeName: String,
        modelIdentifier: String,
        estimatedDownloadGB: Double,
        requiresAppleSilicon: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.runtimeName = runtimeName
        self.modelIdentifier = modelIdentifier
        self.estimatedDownloadGB = estimatedDownloadGB
        self.requiresAppleSilicon = requiresAppleSilicon
    }
}

/// One Qwen3-TTS model the app can install: where it comes from (pinned revision) and the exact weight files it must have.
public struct Qwen3TTSModelVariant: Equatable, Sendable {
    public struct ExpectedFile: Equatable, Sendable {
        public let path: String
        public let bytes: Int
        public let sha256: String
    }

    public let engineIdentifier: String
    public let displayName: String
    public let modelIdentifier: String
    public let revision: String
    public let folderName: String
    public let estimatedDownloadGB: Double
    public let expectedFiles: [ExpectedFile]

    public static let base06B = Qwen3TTSModelVariant(
        engineIdentifier: "qwen3-tts.mlx.0.6b-base", displayName: "Qwen3-TTS 0.6B",
        modelIdentifier: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16",
        revision: "1eccf1cb2519b5a4e8a95b5f0544f3303568164f", folderName: "Qwen3-TTS-12Hz-0.6B-Base-bf16",
        estimatedDownloadGB: 2.52, expectedFiles: [
            .init(path: "model.safetensors", bytes: 1_829_344_448,
                  sha256: "d7c7ed3e3464e3e59de0f955b3755891fa8319ff061c3f0307fe2e1343bc122d"),
            .init(path: "speech_tokenizer/model.safetensors", bytes: 682_293_092,
                  sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258")])

    /// Chosen by the user on 2026-10-19 after listening (V1: first sound 1.4 s, 0.71× real time, 4.7 GB peak on the M5).
    public static let base17B = Qwen3TTSModelVariant(
        engineIdentifier: "qwen3-tts.mlx.1.7b-base", displayName: "Qwen3-TTS 1.7B",
        modelIdentifier: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
        revision: "a6eb4f68e4b056f1215157bb696209bc82a6db48", folderName: "Qwen3-TTS-12Hz-1.7B-Base-bf16",
        estimatedDownloadGB: 4.54, expectedFiles: [
            .init(path: "model.safetensors", bytes: 3_857_414_009,
                  sha256: "81fb76175ff74e69be25fef2cc3e54f016df3034f1514c8e1c89da06a3510cff"),
            .init(path: "speech_tokenizer/model.safetensors", bytes: 682_293_092,
                  sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258")])
}

public enum VoiceEngineCatalog {
    public static let qwen3TTSMLXRuntimeVersion = "0.5.1"
    /// The model the app installs and speaks with.
    public static let qwen3TTSMLXVariant = Qwen3TTSModelVariant.base17B
    public static let qwen3TTSMLXModelRevision = qwen3TTSMLXVariant.revision

    public static let qwen3TTSMLX = VoiceEngineCatalogEntry(
        id: qwen3TTSMLXVariant.engineIdentifier,
        displayName: qwen3TTSMLXVariant.displayName,
        runtimeName: "MLX-Audio \(qwen3TTSMLXRuntimeVersion)",
        modelIdentifier: qwen3TTSMLXVariant.modelIdentifier,
        estimatedDownloadGB: qwen3TTSMLXVariant.estimatedDownloadGB,
        requiresAppleSilicon: true
    )
}

public struct VoiceEngineSynthesisRequest: Equatable, Sendable {
    public let text: String
    public let languageCode: String
    public let capsuleID: UUID
    public let capsuleRevisionHash: String
    public let hasReferenceTranscript: Bool

    public init(
        text: String,
        languageCode: String,
        capsuleID: UUID,
        capsuleRevisionHash: String,
        hasReferenceTranscript: Bool
    ) {
        self.text = text
        self.languageCode = languageCode
        self.capsuleID = capsuleID
        self.capsuleRevisionHash = capsuleRevisionHash
        self.hasReferenceTranscript = hasReferenceTranscript
    }
}

public enum VoiceEngineSynthesisPolicyError: LocalizedError, Equatable, Sendable {
    case engineNotReady
    case invalidText
    case invalidLanguage
    case invalidCapsuleRevision
    case invalidCapsule(VoiceCapsulePolicyError)
    case referenceTranscriptRequired

    public var errorDescription: String? {
        switch self {
        case .engineNotReady:
            "ローカル音声エンジンの準備が完了していません。"
        case .invalidText:
            "読み上げる文章が空か、長すぎます。"
        case .invalidLanguage:
            "この音声の言語設定を確認してください。"
        case .invalidCapsuleRevision:
            "声モデルの内容確認情報が壊れています。"
        case .invalidCapsule(let error):
            error.localizedDescription
        case .referenceTranscriptRequired:
            "高品質な声の再現には、見本音声の正確な文字起こしが必要です。"
        }
    }
}

public enum VoiceEngineSynthesisPolicy {
    public static let maximumTextCharacters = 1_200

    public static func validationError(
        for request: VoiceEngineSynthesisRequest,
        manifest: VoiceCapsuleManifest,
        readiness: VoiceEngineReadiness
    ) -> VoiceEngineSynthesisPolicyError? {
        guard readiness.engineIdentifier == VoiceEngineCatalog.qwen3TTSMLX.id,
              readiness.canSynthesize else {
            return .engineNotReady
        }
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumTextCharacters else {
            return .invalidText
        }
        let language = request.languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !language.isEmpty, language.count <= 24,
              !language.contains("\n"), !language.contains("\r") else {
            return .invalidLanguage
        }
        guard request.capsuleID == manifest.id,
              VisualContentHash.isValidSHA256(request.capsuleRevisionHash) else {
            return .invalidCapsuleRevision
        }
        if let error = VoiceCapsulePolicy.validationError(for: manifest) {
            return .invalidCapsule(error)
        }
        guard request.hasReferenceTranscript,
              manifest.references.first?.transcriptContentHash != nil else {
            return .referenceTranscriptRequired
        }
        return nil
    }
}
