import Foundation
import HarnessCore

/// Where the per-purpose model catalog lives and which option the user picked (2026-10-09). The catalog file is local:
/// `<checkout>/config/purpose-models.json`, else `~/Library/Application Support/Harness/purpose-models.json`. No file, no
/// extra options: writing and image generation then use the project's own model, as before.
struct PurposeModelSettings {
    static func key(_ purpose: ModelPurpose) -> String { "harness.purposeModel.\(purpose.rawValue)" }

    let catalog: PurposeModelCatalog
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, catalog: PurposeModelCatalog? = nil) {
        self.defaults = defaults
        self.catalog = catalog ?? Self.catalogURL().map(PurposeModelCatalog.load) ?? .empty
    }

    static func catalogURL(checkout: String? = OrchestratedRunSettings().candidatePath) -> URL? {
        let candidates = [checkout.map { URL(fileURLWithPath: $0).appendingPathComponent("config/purpose-models.json") },
                          FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                              .appendingPathComponent("Harness/purpose-models.json")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The option the user picked for a purpose; nil means the project's model (the default).
    func chosen(_ purpose: ModelPurpose) -> PurposeModelOption? {
        catalog.option(id: defaults.string(forKey: Self.key(purpose)), for: purpose)
    }

    func choose(_ id: String?, for purpose: ModelPurpose) {
        if let id { defaults.set(id, forKey: Self.key(purpose)) } else { defaults.removeObject(forKey: Self.key(purpose)) }
    }
}

/// What the next message is for, picked in the composer (chat mode only; code mode is always conversation). Writing and image skip the code-change routing and the system
/// model's intent check: the purpose is the user's own choice.
enum ComposerPurpose: String, CaseIterable, Identifiable {
    case conversation, writing, image, video
    var id: String { rawValue }
    var title: String {
        switch self {
        case .conversation: "会話"
        case .writing: "文章を書く"
        case .image: "画像を作る"
        case .video: "動画を作る"
        }
    }
    var symbol: String {
        switch self {
        case .conversation: "bubble.left.and.bubble.right"
        case .writing: "pencil.and.scribble"
        case .image: "photo.artframe"
        case .video: "film"
        }
    }
}
