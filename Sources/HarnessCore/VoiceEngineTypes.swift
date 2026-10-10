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

public enum VoiceEngineCatalog {
    public static let qwen3TTSMLXRuntimeVersion = "0.5.1"
    public static let qwen3TTSMLXModelRevision =
        "1eccf1cb2519b5a4e8a95b5f0544f3303568164f"

    public static let qwen3TTSMLX = VoiceEngineCatalogEntry(
        id: "qwen3-tts.mlx.0.6b-base",
        displayName: "Qwen3-TTS 0.6B",
        runtimeName: "MLX-Audio \(qwen3TTSMLXRuntimeVersion)",
        modelIdentifier: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16",
        estimatedDownloadGB: 2.52,
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
