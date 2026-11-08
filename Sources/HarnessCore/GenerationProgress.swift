import Foundation

/// How far a running picture or video has got, written by the generating script beside its output as
/// `<output>.progress` (2026-11-08, the user: the remaining time stopped meaning anything once a job could remake its clips;
/// show progress as a bar). `{"step": 3, "of": 6, "label": "はだけの動画(2 回目)"}`.
public struct GenerationProgress: Codable, Equatable, Sendable {
    public var step: Int
    public var of: Int
    public var label: String

    public init(step: Int, of: Int, label: String) { self.step = step; self.of = of; self.label = label }

    /// Between 0 and 1: the steps already done (the current one counts as half done).
    public var fraction: Double { of > 0 ? min(1, max(0, (Double(step) - 0.5) / Double(of))) : 0 }

    public static func file(for output: URL) -> URL { output.appendingPathExtension("progress") }

    public static func read(for output: URL) -> GenerationProgress? {
        guard let data = try? Data(contentsOf: file(for: output)) else { return nil }
        return try? JSONDecoder().decode(GenerationProgress.self, from: data)
    }
}
