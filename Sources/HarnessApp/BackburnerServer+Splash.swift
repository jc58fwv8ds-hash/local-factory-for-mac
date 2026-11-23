import Foundation

/// A 27B fine-tune (Qwen3.8-27B family) served by splash (github.com/incoai/splash) with its DFlash2 drafter, instead of
/// llama-server without speculation (2026-11-23, Saluki on this M5 32GB, the same Factory edit request: llama-server 12.1
/// tokens/s, its own MTP heads at best 16.4, splash 45; JSON replies kept their schema).
extension BackburnerServer {
    static let splashExecutable = "/opt/homebrew/bin/splash"
    static var splashDrafter: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models/Qwen3.8-27B-DFlash2")
    }

    /// The arguments for splash on 8080, or nil when it cannot serve this model (not installed, no drafter, not a 27B,
    /// or a model with its own image encoder, which splash's text-only start leaves out).
    static func splashArguments(model: String) -> [String]? {
        let file = FileManager.default
        guard file.isExecutableFile(atPath: splashExecutable),
              file.fileExists(atPath: splashDrafter.appendingPathComponent("config.json").path),
              (model as NSString).lastPathComponent.contains("27B") else { return nil }
        let projector = URL(fileURLWithPath: model).deletingPathExtension().appendingPathExtension("mmproj.gguf")
        guard !file.fileExists(atPath: projector.path) else { return nil }
        return ["serve", "--model", "local/backburner", "--model-dir", model, "--draft-model", splashDrafter.path,
                "--served-model-name", identifier(for: model), "--language-only", "--offline",
                "--port", "8080", "--max-context", "65536", "--no-webui"]
    }

    /// The identifier requests name this model by (catalog form, the home folder as {home}).
    static func identifier(for model: String) -> String {
        "gguf:" + model.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "{home}")
    }

    /// splash's launcher, its Python server and its native engine.
    static func stopSplash() {
        for pattern in ["libexec/engine/splash", "splash/[0-9.]*/libexec/python", "bin/splash serve"] {
            _ = run("/usr/bin/pkill", ["-f", pattern])
        }
    }
}
