import Foundation

public enum VisualModelCapability: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case textConversation
    case imageUnderstanding
    case imageGeneration
    case imageEditing
}

public enum VisualTask: String, Codable, Equatable, Sendable {
    case understandReference
    case deterministicEdit
    case generateNewImage
    case generativeEdit
}

public enum VisualProcessingRoute: String, Codable, Equatable, Sendable {
    case visionModel
    case localImagePipeline
    case imageGenerationModel
    case imageEditingModel
}

public struct VisualRoutingDecision: Equatable, Sendable {
    public let route: VisualProcessingRoute?
    public let missingCapability: VisualModelCapability?
    public let userMessage: String

    public init(
        route: VisualProcessingRoute?,
        missingCapability: VisualModelCapability?,
        userMessage: String
    ) {
        self.route = route
        self.missingCapability = missingCapability
        self.userMessage = userMessage
    }
}

public enum VisualModelRoutingPolicy {
    /// Text conversation is never treated as proof that a model can see or edit pixels.
    public static func decision(
        for task: VisualTask,
        capabilities: Set<VisualModelCapability>
    ) -> VisualRoutingDecision {
        switch task {
        case .deterministicEdit:
            VisualRoutingDecision(
                route: .localImagePipeline,
                missingCapability: nil,
                userMessage: "余白・切り抜き・大きさ・色味はMac上で処理できます。"
            )
        case .understandReference:
            requiring(
                .imageUnderstanding,
                route: .visionModel,
                capabilities: capabilities,
                unavailable: "画像を見るAIモデルがまだありません。対応モデルを追加すると内容を確認できます。"
            )
        case .generateNewImage:
            requiring(
                .imageGeneration,
                route: .imageGenerationModel,
                capabilities: capabilities,
                unavailable: "画像を作るAIモデルがまだありません。生成対応モデルを追加してください。"
            )
        case .generativeEdit:
            requiring(
                .imageEditing,
                route: .imageEditingModel,
                capabilities: capabilities,
                unavailable: "画像を生成編集できるAIモデルがまだありません。編集対応モデルを追加してください。"
            )
        }
    }

    private static func requiring(
        _ capability: VisualModelCapability,
        route: VisualProcessingRoute,
        capabilities: Set<VisualModelCapability>,
        unavailable: String
    ) -> VisualRoutingDecision {
        guard capabilities.contains(capability) else {
            return VisualRoutingDecision(
                route: nil,
                missingCapability: capability,
                userMessage: unavailable
            )
        }
        return VisualRoutingDecision(
            route: route,
            missingCapability: nil,
            userMessage: "必要な画像処理を始められます。"
        )
    }
}
