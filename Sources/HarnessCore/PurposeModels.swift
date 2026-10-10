import Foundation

/// Models chosen per purpose (2026-10-09): writing and image generation can use other models than the project's
/// conversation model. The options come from a local catalog file (purpose-models.json), not from the app: without one,
/// only the project's model is offered. Nothing here is used unless the user picks an option in the settings.
public enum ModelPurpose: String, Codable, CaseIterable, Sendable {
    case writing
    case image

    public var title: String {
        switch self {
        case .writing: "文章を書く"
        case .image: "画像を作る"
        }
    }
}

public struct PurposeModelOption: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var note: String?
    /// Writing: the runtime and model identifier the inference service calls.
    public var runtime: RuntimeKind?
    public var model: String?
    /// Image: the command line; {prompt}, {output}, {seed}, {width}, {height}, {home} are filled in.
    public var command: [String]?

    public init(id: String, label: String, note: String? = nil, runtime: RuntimeKind? = nil, model: String? = nil,
                command: [String]? = nil) {
        self.id = id; self.label = label; self.note = note; self.runtime = runtime; self.model = model; self.command = command
    }

    public var selection: ModelSelection? {
        guard let runtime, let model else { return nil }
        return ModelSelection(identifier: model, displayName: label, runtime: runtime)
    }
}

public struct PurposeModelCatalog: Codable, Equatable, Sendable {
    public var writing: [PurposeModelOption]
    public var image: [PurposeModelOption]
    /// When a writing option is chosen, every model role in that flow follows it: the "large" role (the project's 27B-class
    /// model) and the "checker" role (the second model that rechecks). Ids of writing options.
    public var roles: [String: String]?
    /// A code change the normal model refuses is retried once with this writing option (id).
    public var codeRefusalFallback: String?

    public init(writing: [PurposeModelOption] = [], image: [PurposeModelOption] = [], roles: [String: String]? = nil,
                codeRefusalFallback: String? = nil) {
        self.writing = writing; self.image = image; self.roles = roles; self.codeRefusalFallback = codeRefusalFallback
    }

    public static let empty = PurposeModelCatalog()

    public static func load(from url: URL) -> PurposeModelCatalog {
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(PurposeModelCatalog.self, from: data) else { return .empty }
        return catalog
    }

    public func options(for purpose: ModelPurpose) -> [PurposeModelOption] {
        purpose == .writing ? writing : image
    }

    public func option(id: String?, for purpose: ModelPurpose) -> PurposeModelOption? {
        guard let id else { return nil }
        return options(for: purpose).first { $0.id == id }
    }

    /// The model for a role ("large" or "checker") in a flow where `chosen` was picked, if the catalog aligns roles.
    public func roleModel(_ role: String, chosen: PurposeModelOption) -> ModelSelection? {
        guard let id = roles?[role], let option = writing.first(where: { $0.id == id }) else { return chosen.selection }
        return option.selection
    }
}

/// A refusal in a model's answer (Japanese and English phrasings), for retrying a code change once with another model.
public enum ModelRefusal {
    static let phrases = ["申し訳ありませんが", "お手伝いできません", "お応えできません", "対応できません", "提供できません",
                          "I can't help with", "I cannot help with", "I can't assist", "I cannot assist", "I'm not able to help",
                          "I won't be able to"]

    public static func looksLikeRefusal(_ text: String) -> Bool {
        let head = String(text.prefix(400))
        return phrases.contains { head.localizedCaseInsensitiveContains($0) }
    }
}
