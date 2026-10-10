import Foundation

public struct ModelHostResources: Equatable, Sendable {
    public let physicalMemoryBytes: Int64?
    public let availableDiskBytes: Int64?

    public init(
        physicalMemoryBytes: Int64?,
        availableDiskBytes: Int64?
    ) {
        self.physicalMemoryBytes = Self.positive(physicalMemoryBytes)
        self.availableDiskBytes = Self.positive(availableDiskBytes)
    }

    public static func current(
        storageURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ModelHostResources {
        let reportedMemory = ProcessInfo.processInfo.physicalMemory
        let memory = reportedMemory > UInt64(Int64.max)
            ? Int64.max
            : Int64(reportedMemory)
        let disk = try? storageURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage

        return ModelHostResources(
            physicalMemoryBytes: memory,
            availableDiskBytes: disk ?? nil
        )
    }

    private static func positive(_ value: Int64?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

public enum ModelFitLevel: String, Equatable, Sendable {
    case suitable
    case constrained
    case notRecommended
    case insufficientStorage
    case unknown
}

public struct ModelFitAssessment: Equatable, Sendable {
    public let level: ModelFitLevel
    public let minimumMemoryBytes: Int64?
    public let recommendedMemoryBytes: Int64?
    public let requiredDiskBytes: Int64?

    public var canInstall: Bool { level != .insufficientStorage }

    public init(
        level: ModelFitLevel,
        minimumMemoryBytes: Int64?,
        recommendedMemoryBytes: Int64?,
        requiredDiskBytes: Int64?
    ) {
        self.level = level
        self.minimumMemoryBytes = minimumMemoryBytes
        self.recommendedMemoryBytes = recommendedMemoryBytes
        self.requiredDiskBytes = requiredDiskBytes
    }
}

public enum ModelFitPolicy {
    private static let bytesPerGigabyte = 1_000_000_000.0

    public static func assess(
        _ entry: ModelCatalogEntry,
        on resources: ModelHostResources
    ) -> ModelFitAssessment {
        guard entry.estimatedSizeGB > 0 else {
            return ModelFitAssessment(
                level: .unknown,
                minimumMemoryBytes: nil,
                recommendedMemoryBytes: nil,
                requiredDiskBytes: nil
            )
        }

        let modelBytes = entry.estimatedSizeGB * bytesPerGigabyte
        let minimumMemory = byteCount(modelBytes * 1.1 + 4 * bytesPerGigabyte)
        let recommendedMemory = byteCount(modelBytes * 1.35 + 6 * bytesPerGigabyte)
        let requiredDisk = byteCount(modelBytes * 1.25 + 2 * bytesPerGigabyte)

        if let availableDisk = resources.availableDiskBytes,
           availableDisk < requiredDisk {
            return ModelFitAssessment(
                level: .insufficientStorage,
                minimumMemoryBytes: minimumMemory,
                recommendedMemoryBytes: recommendedMemory,
                requiredDiskBytes: requiredDisk
            )
        }

        let level: ModelFitLevel
        if let physicalMemory = resources.physicalMemoryBytes {
            if physicalMemory >= recommendedMemory {
                level = .suitable
            } else if physicalMemory >= minimumMemory {
                level = .constrained
            } else {
                level = .notRecommended
            }
        } else {
            level = .unknown
        }

        return ModelFitAssessment(
            level: level,
            minimumMemoryBytes: minimumMemory,
            recommendedMemoryBytes: recommendedMemory,
            requiredDiskBytes: requiredDisk
        )
    }

    private static func byteCount(_ value: Double) -> Int64 {
        Int64(value.rounded(.up))
    }
}
