import Foundation

/// Models chosen per purpose (2026-10-09): writing and image generation can use other models than the project's
/// conversation model. The options come from a local catalog file (purpose-models.json), not from the app: without one,
/// only the project's model is offered. Nothing here is used unless the user picks an option in the settings.
public enum ModelPurpose: String, Codable, CaseIterable, Sendable {
    /// Conversation in chat mode (2026-11-02, the user: the chat's conversation uses a model of their choice).
    case conversation
    case writing
    case image
    case video

    public var title: String {
        switch self {
        case .conversation: "会話"
        case .writing: "文章を書く"
        case .image: "画像を作る"
        case .video: "動画を作る"
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
    /// A short mark shown wherever this option is picked or in use (2026-10-19, the user's request: options with fewer
    /// safety limits must be easy to tell apart). The words come from the local catalog, not from the app.
    public var badge: String?
    /// How long one run may take, in seconds, before it is stopped; absent means 20 minutes (more for a long video).
    /// (2026-11-08: the picture model that keeps a person remakes clips that did not open or move, and was stopped at 20
    /// minutes in the middle of its last clip.)
    public var timeLimit: Double?
    /// A quicker command tried first (2026-11-08): its picture is shown to the prompt writer, and `command` runs only when
    /// the writer says it does not show what was asked. Same placeholders as `command`.
    public var firstTry: [String]?
    /// A video longer than one clip, made scene by scene (2026-11-08): {plan} (the scenes, JSON), {image}, {output},
    /// {seed}, {seconds} (one scene), {home}.
    public var longCommand: [String]?

    public init(id: String, label: String, note: String? = nil, runtime: RuntimeKind? = nil, model: String? = nil,
                command: [String]? = nil, badge: String? = nil) {
        self.id = id; self.label = label; self.note = note; self.runtime = runtime; self.model = model; self.command = command
        self.badge = badge
    }

    public var selection: ModelSelection? {
        guard let runtime, let model else { return nil }
        return ModelSelection(identifier: model, displayName: label, runtime: runtime)
    }
}

public struct PurposeModelCatalog: Codable, Equatable, Sendable {
    public var writing: [PurposeModelOption]
    public var image: [PurposeModelOption]
    /// Video generation (2026-10-19): command-line options like image; absent in older catalog files.
    public var video: [PurposeModelOption]?
    /// Conversation options (2026-11-02); absent in older catalog files.
    public var conversation: [PurposeModelOption]?
    /// When a writing option is chosen, every model role in that flow follows it: the "large" role (the project's 27B-class
    /// model) and the "checker" role (the second model that rechecks). Ids of writing options.
    public var roles: [String: String]?
    /// A code change the normal model refuses is retried once with this writing option (id).
    public var codeRefusalFallback: String?
    /// Words in a request and the motion sentence always added to the picture or video prompt for them (2026-11-07: the
    /// prompt writer softened acts into still poses; a direct motion sentence made the video model draw them). The user's
    /// to edit in the catalog file.
    public var motionHints: [String: String]?

    /// The motion sentences for the words in `request`, each once, in the catalog's key order.
    public func motionHints(for request: String) -> [String] {
        guard let motionHints else { return [] }
        return Array(Set(motionHints.keys.filter { request.contains($0) }.compactMap { motionHints[$0] })).sorted()
    }

    /// The command that lays a Japanese voice over a finished video when the request asks for one (2026-11-08), with
    /// {home}, {video}, {text}, {caption}, {output} and {seed}.
    public var voiceCommand: [String]?
    /// The command that only speaks: {text}, {caption}, {output} (a .wav), {seed}, {home}. Its voice goes to a video model
    /// whose command takes {audio}, which moves the mouth with it (2026-11-08).
    public var speechCommand: [String]?

    /// Japanese words and the English the prompt writer must use for them (2026-11-08: 「アトリエ」 became a white photo
    /// studio and 「浴衣」 a bathrobe). The user's to edit in the catalog file.
    public var termHints: [String: String]?

    /// "word = meaning" for each word of `request` in `termHints`, sorted.
    public func termHints(for request: String) -> [String] {
        guard let termHints else { return [] }
        return termHints.keys.filter { request.contains($0) }.sorted().compactMap { key in termHints[key].map { "「\(key)」 = \($0)" } }
    }

    public init(writing: [PurposeModelOption] = [], image: [PurposeModelOption] = [], video: [PurposeModelOption]? = nil,
                roles: [String: String]? = nil, codeRefusalFallback: String? = nil, conversation: [PurposeModelOption]? = nil) {
        self.writing = writing; self.image = image; self.video = video; self.roles = roles; self.conversation = conversation
        self.codeRefusalFallback = codeRefusalFallback
    }

    public static let empty = PurposeModelCatalog()

    public static func load(from url: URL) -> PurposeModelCatalog {
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(PurposeModelCatalog.self, from: data) else { return .empty }
        return catalog
    }

    public func options(for purpose: ModelPurpose) -> [PurposeModelOption] {
        switch purpose {
        case .conversation: conversation ?? []
        case .writing: writing
        case .image: image
        case .video: video ?? []
        }
    }

    public func option(id: String?, for purpose: ModelPurpose) -> PurposeModelOption? {
        guard let id else { return nil }
        return options(for: purpose).first { $0.id == id }
    }

    /// `option`, or, when it keeps a person from a picture (its command takes {image}) and there is no picture, the first
    /// picture model that does not need one (2026-11-11: 「人物を保って作る」, left chosen from an earlier chat, failed in a
    /// new chat with "At least one init image is required").
    /// `keepsPerson`: the request names the person in the picture (「画像の人物が…」). A plain picture model then hands over to
    /// the one that keeps a person (2026-11-13: with a plain model chosen, 「画像の人物が香港で…」 drew someone else from the
    /// prompt's description, and the same person was never kept).
    public func pictureModel(_ option: PurposeModelOption, hasPicture: Bool, keepsPerson: Bool = false) -> PurposeModelOption {
        let keeps = option.command?.contains("{image}") == true
        if hasPicture, keepsPerson, !keeps, let keeper = image.first(where: { $0.command?.contains("{image}") == true }) { return keeper }
        guard !hasPicture, keeps else { return option }
        return image.first { $0.command?.contains("{image}") != true } ?? option
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
                          "I won't be able to", "I cannot fulfill", "I can't fulfill", "I cannot create", "I can't create",
                          "I cannot generate", "I can't generate", "I cannot provide", "I can't provide", "I'm sorry, but", "I am designed to be a helpful and harmless"]

    public static func looksLikeRefusal(_ text: String) -> Bool {
        let head = String(text.prefix(400))
        return phrases.contains { head.localizedCaseInsensitiveContains($0) }
    }
}
