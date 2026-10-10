import Foundation

public struct SourceContextBudget: Equatable, Sendable {
    public let maxEntries: Int
    public let maxFiles: Int
    public let maxFileBytes: Int
    public let maxTotalCharacters: Int

    public init(
        maxEntries: Int,
        maxFiles: Int,
        maxFileBytes: Int,
        maxTotalCharacters: Int
    ) {
        self.maxEntries = max(1, maxEntries)
        self.maxFiles = max(1, maxFiles)
        self.maxFileBytes = max(1_024, maxFileBytes)
        self.maxTotalCharacters = max(2_048, maxTotalCharacters)
    }

    public static let compact = SourceContextBudget(
        maxEntries: 4_000,
        maxFiles: 10,
        maxFileBytes: 16_000,
        maxTotalCharacters: 24_000
    )

    public static let standard = SourceContextBudget(
        maxEntries: 4_000,
        maxFiles: 18,
        maxFileBytes: 24_000,
        maxTotalCharacters: 48_000
    )
}

public enum SourceContextBudgetPolicy {
    public static func budget(for model: ModelSelection) -> SourceContextBudget {
        parameterCount(in: "\(model.identifier) \(model.displayName)") >= 20
            ? .standard
            : .compact
    }

    private static func parameterCount(in modelDescription: String) -> Double {
        modelDescription
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .compactMap { token -> Double? in
                guard token.hasSuffix("b") else { return nil }
                return Double(token.dropLast())
            }
            .max() ?? 0
    }
}
