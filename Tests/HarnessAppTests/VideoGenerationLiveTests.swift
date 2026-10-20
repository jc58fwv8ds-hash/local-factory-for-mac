import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

/// A real video through the app's runner (2026-10-19): the catalog's command, the language models released first, an
/// .mp4 at the output path. HARNESS_VIDEO_LIVE=<catalog option id>.
struct VideoGenerationLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_VIDEO_LIVE"] != nil), .timeLimit(.minutes(25)))
    func theCatalogVideoOptionMakesAnMP4() async throws {
        let id = ProcessInfo.processInfo.environment["HARNESS_VIDEO_LIVE"]!
        let catalog = PurposeModelCatalog.load(from: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config/purpose-models.json"))
        let option = try #require(catalog.option(id: id, for: .video))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).mp4")
        let started = ContinuousClock.now
        try await ImageGenerationService().generate(option: option, prompt:
            "Paper lanterns sway gently over a quiet night street, light rain, soft reflections", output: output)
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        print("動画: \(output.path) \(size) バイト / \(ContinuousClock.now - started)")
        #expect(size > 100_000)
    }
}
