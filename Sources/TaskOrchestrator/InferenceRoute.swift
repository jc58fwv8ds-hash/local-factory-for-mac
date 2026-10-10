import Foundation
import HarnessCore

/// Which local runtime serves a model name. "openai:<name>" goes to an OpenAI-compatible server (llama-server, e.g.
/// Backburner; URL from HARNESS_OPENAI_COMPATIBLE_URL); every other name keeps the stage's own runtime (Ollama).
package enum InferenceRoute {
    package static let prefix = "openai:"
    /// "backburner:<name>" goes to the App-managed Backburner server (fixed 127.0.0.1:8080), so the App never depends on
    /// an environment variable.
    package static let backburnerPrefix = "backburner:"
    package static func resolve(_ model: String, default runtime: RuntimeKind) -> (runtime: RuntimeKind, model: String) {
        let name = baseName(model)
        if name.hasPrefix(backburnerPrefix) { return (.backburner, String(name.dropFirst(backburnerPrefix.count))) }
        return name.hasPrefix(prefix) ? (.lmStudio, String(name.dropFirst(prefix.count))) : (runtime, name)
    }

    /// "<model>@t0.7" samples at that temperature (a second, more varied candidate from the same model).
    package static func temperature(_ model: String) -> Double? {
        guard let range = model.range(of: "@t", options: .backwards) else { return nil }
        return Double(model[range.upperBound...])
    }

    static func baseName(_ model: String) -> String {
        guard temperature(model) != nil, let range = model.range(of: "@t", options: .backwards) else { return model }
        return String(model[..<range.lowerBound])
    }
}
