import Foundation
import HarnessCore

enum ModelHostResourceChecks {
    private static let gigabyte: Int64 = 1_000_000_000

    static func run() throws {
        let model = try require(ModelCatalogEntry.recommended.first)

        let suitable = ModelFitPolicy.assess(
            model,
            on: resources(memoryGB: 32, diskGB: 100)
        )
        try expect(
            suitable.level == .suitable
                && suitable.canInstall
                && (suitable.minimumMemoryBytes ?? 0) >= 22 * gigabyte
                && (suitable.recommendedMemoryBytes ?? 0) >= 28 * gigabyte
                && (suitable.requiredDiskBytes ?? 0) == 23 * gigabyte,
            "A 32 GB Mac should be suitable for the configured 27B Q4 model"
        )

        let constrained = ModelFitPolicy.assess(
            model,
            on: resources(memoryGB: 24, diskGB: 100)
        )
        try expect(
            constrained.level == .constrained && constrained.canInstall,
            "A memory-constrained host should receive a warning without blocking installation"
        )

        let notRecommended = ModelFitPolicy.assess(
            model,
            on: resources(memoryGB: 16, diskGB: 100)
        )
        try expect(
            notRecommended.level == .notRecommended
                && notRecommended.canInstall,
            "A host below the estimated runtime memory should be marked not recommended"
        )

        let insufficientStorage = ModelFitPolicy.assess(
            model,
            on: resources(memoryGB: 32, diskGB: 20)
        )
        try expect(
            insufficientStorage.level == .insufficientStorage
                && !insufficientStorage.canInstall,
            "Insufficient installation headroom must block model acquisition"
        )

        let unknown = ModelFitPolicy.assess(
            ModelCatalogEntry(
                id: "custom",
                displayName: "Custom",
                summary: "Unknown size",
                parameterLabel: "Custom",
                estimatedSizeGB: 0,
                isRecommended: false,
                ollamaIdentifier: "custom",
                lmStudioIdentifier: "custom"
            ),
            on: ModelHostResources(
                physicalMemoryBytes: nil,
                availableDiskBytes: nil
            )
        )
        try expect(
            unknown.level == .unknown && unknown.canInstall,
            "Unknown custom model sizes should remain installable with an explicit unknown state"
        )

        let normalized = ModelHostResources(
            physicalMemoryBytes: 0,
            availableDiskBytes: -1
        )
        try expect(
            normalized.physicalMemoryBytes == nil
                && normalized.availableDiskBytes == nil,
            "Invalid resource probe values must not become misleading capacity data"
        )

        print("✓ Model installation is gated by disk headroom and explained by real host memory")
    }

    private static func resources(memoryGB: Int64, diskGB: Int64) -> ModelHostResources {
        ModelHostResources(
            physicalMemoryBytes: memoryGB * gigabyte,
            availableDiskBytes: diskGB * gigabyte
        )
    }
}
