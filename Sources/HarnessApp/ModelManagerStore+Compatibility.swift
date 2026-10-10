import Foundation
import HarnessCore

extension ModelManagerStore {
    func fitAssessment(for entry: ModelCatalogEntry) -> ModelFitAssessment {
        ModelFitPolicy.assess(entry, on: hostResources)
    }

    var hostResourceSummary: String {
        let memory = hostResources.physicalMemoryBytes.map(Self.capacityLabel) ?? "メモリ不明"
        let disk = hostResources.availableDiskBytes.map(Self.capacityLabel) ?? "空き容量不明"
        return "メモリ \(memory) ・ 起動ディスク空き \(disk)"
    }

    func installationAdvice(for entry: ModelCatalogEntry) -> String {
        let assessment = fitAssessment(for: entry)
        let recommendedMemory = assessment.recommendedMemoryBytes
            .map(Self.capacityLabel)

        switch assessment.level {
        case .suitable:
            return "このMacのメモリと空き容量に適合しています。"
        case .constrained:
            let target = recommendedMemory.map { "快適動作の目安は\($0)です。" } ?? ""
            return "実行できますが、同時に使うアプリを減らしてください。\(target)"
        case .notRecommended:
            let target = recommendedMemory.map { "快適動作の目安は\($0)です。" } ?? ""
            return "このMacではメモリ不足になる可能性が高いため、小さいモデルを推奨します。\(target)"
        case .insufficientStorage:
            let required = assessment.requiredDiskBytes
                .map(Self.capacityLabel) ?? "追加の"
            return "安全な取得には約\(required)の空き容量が必要です。"
        case .unknown:
            return "モデル容量が不明なため、必要なメモリと空き容量は確認できません。"
        }
    }

    func validateInstallationCapacity(for entry: ModelCatalogEntry) -> Bool {
        let assessment = fitAssessment(for: entry)
        guard assessment.canInstall else {
            errorMessage = installationAdvice(for: entry)
            return false
        }
        return true
    }

    private static func capacityLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .decimal
        )
    }
}
