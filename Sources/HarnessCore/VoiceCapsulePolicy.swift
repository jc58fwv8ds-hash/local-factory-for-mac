import Foundation

public enum VoiceCapsulePolicyError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema
    case invalidName
    case missingReference
    case tooManyReferences
    case invalidReferenceName
    case invalidReferenceDuration
    case invalidContentHash
    case missingConsent
    case exportNeedsVerifiedConsent
    case invalidStyle

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "この声データの形式にはまだ対応していません。"
        case .invalidName: "声の名前を確認してください。"
        case .missingReference: "声の元になる短い音声が必要です。"
        case .tooManyReferences: "参照音声が多すぎます。良質な候補を5つ以内に絞ってください。"
        case .invalidReferenceName: "参照音声の名前を確認してください。"
        case .invalidReferenceDuration: "参照音声は1区間3〜30秒にしてください。"
        case .invalidContentHash: "声データの内容確認情報が壊れています。"
        case .missingConsent: "本人または権利者の同意を確認できないため、この声は作れません。"
        case .exportNeedsVerifiedConsent: "声を外へ書き出すには、話者確認を含む同意が必要です。"
        case .invalidStyle: "話し方・感情・言語・速度の設定を確認してください。"
        }
    }
}

public enum VoiceCapsulePolicy {
    public static let maximumReferenceCount = 5
    public static let minimumReferenceDurationMilliseconds = 3_000
    public static let maximumReferenceDurationMilliseconds = 30_000

    public static func validationError(
        for manifest: VoiceCapsuleManifest
    ) -> VoiceCapsulePolicyError? {
        guard manifest.schemaVersion == VoiceCapsuleManifest.currentSchemaVersion else {
            return .unsupportedSchema
        }
        let name = manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { return .invalidName }

        if manifest.kind == .preset {
            guard manifest.consent.status == .notRequiredForPreset else { return .missingConsent }
        } else {
            guard !manifest.references.isEmpty else { return .missingReference }
            guard manifest.consent.status == .recordedLocally
                    || manifest.consent.status == .userAttestedPrivateUse
                    || manifest.consent.status == .externallyVerified else {
                return .missingConsent
            }
        }
        guard manifest.references.count <= maximumReferenceCount else {
            return .tooManyReferences
        }

        for reference in manifest.references {
            let referenceName = reference.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !referenceName.isEmpty, referenceName.count <= 120 else {
                return .invalidReferenceName
            }
            guard reference.durationMilliseconds >= minimumReferenceDurationMilliseconds,
                  reference.durationMilliseconds <= maximumReferenceDurationMilliseconds else {
                return .invalidReferenceDuration
            }
            let hashes = [
                reference.audioContentHash,
                reference.transcriptContentHash,
                reference.alignmentContentHash
            ].compactMap { $0 }
            guard hashes.allSatisfy(VisualContentHash.isValidSHA256) else {
                return .invalidContentHash
            }
        }

        if manifest.usageScope == .exportAllowed {
            guard manifest.consent.status == .externallyVerified,
                  manifest.consent.speakerMatchVerified else {
                return .exportNeedsVerifiedConsent
            }
        }
        if let consentHash = manifest.consent.consentRecordingContentHash,
           !VisualContentHash.isValidSHA256(consentHash) {
            return .invalidContentHash
        }

        let style = manifest.styleProfile
        guard !style.style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !style.emotion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !style.languageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              style.speakingRate >= 0.5,
              style.speakingRate <= 2 else {
            return .invalidStyle
        }
        return nil
    }
}
