import Foundation

public struct ModelCatalogEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let parameterLabel: String
    public let estimatedSizeGB: Double
    public let isRecommended: Bool
    public let ollamaIdentifier: String
    public let lmStudioIdentifier: String
    public let matchingTokens: [String]
    public let capabilities: Set<VisualModelCapability>

    public init(
        id: String,
        displayName: String,
        summary: String,
        parameterLabel: String,
        estimatedSizeGB: Double,
        isRecommended: Bool,
        ollamaIdentifier: String,
        lmStudioIdentifier: String,
        matchingTokens: [String] = [],
        capabilities: Set<VisualModelCapability> = [.textConversation]
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.parameterLabel = parameterLabel
        self.estimatedSizeGB = estimatedSizeGB
        self.isRecommended = isRecommended
        self.ollamaIdentifier = ollamaIdentifier
        self.lmStudioIdentifier = lmStudioIdentifier
        self.matchingTokens = matchingTokens
        self.capabilities = capabilities
    }

    public func identifier(for runtime: RuntimeKind) -> String? {
        switch runtime {
        case .harness: nil
        case .ollama: ollamaIdentifier
        case .lmStudio: lmStudioIdentifier
        case .backburner: nil
        }
    }
}

public extension ModelCatalogEntry {
    static let recommended: [ModelCatalogEntry] = [
        ModelCatalogEntry(
            id: "qwen-3.8-27b-q4",
            displayName: "Qwen 3.8 27B",
            summary: "最新世代で設計・実装・検証を長く回す本命候補",
            parameterLabel: "27B ・ Q4_K_M",
            estimatedSizeGB: 16.8,
            isRecommended: true,
            ollamaIdentifier: "hf.co/lmstudio-community/Qwen3.8-27B-GGUF:Q4_K_M",
            lmStudioIdentifier: "https://huggingface.co/lmstudio-community/Qwen3.8-27B-GGUF@Q4_K_M",
            matchingTokens: ["qwen3.8", "27b", "q4"],
            capabilities: [.textConversation, .imageUnderstanding]
        ),
        ModelCatalogEntry(
            id: "qwen-3.5-9b-q4",
            displayName: "Qwen 3.5 9B",
            summary: "軽い修正や要約を素早く行う省メモリモデル",
            parameterLabel: "9B ・ Q4_K_M",
            estimatedSizeGB: 6.6,
            isRecommended: false,
            ollamaIdentifier: "qwen3.5:9b-q4_K_M",
            lmStudioIdentifier: "qwen/qwen3.5-9b@q4_k_m",
            matchingTokens: ["qwen3.5", "9b", "q4"]
        )
    ]
}

public enum VisualModelCapabilityResolver {
    public static func capabilities(for model: ModelSelection) -> Set<VisualModelCapability> {
        if let capabilities = model.capabilities { return capabilities }
        let identifier = model.identifier.lowercased()
        return ModelCatalogEntry.recommended.first { entry in
            !entry.matchingTokens.isEmpty
                && entry.matchingTokens.allSatisfy { identifier.contains($0.lowercased()) }
        }?.capabilities ?? [.textConversation]
    }
}
