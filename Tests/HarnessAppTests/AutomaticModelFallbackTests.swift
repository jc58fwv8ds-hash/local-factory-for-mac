import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

@MainActor
struct AutomaticModelFallbackTests {
    @Test func thePickedWritingModelIsUsedWhenItsFileIsHere() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fallback-\(UUID().uuidString).gguf")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let defaults = UserDefaults(suiteName: "fallback-\(UUID().uuidString)")!
        let catalog = PurposeModelCatalog(writing: [
            PurposeModelOption(id: "here", label: "ここにあるモデル", runtime: .backburner, model: "gguf:" + file.path),
            PurposeModelOption(id: "gone", label: "消えたモデル", runtime: .backburner, model: "gguf:/nowhere/gone.gguf"),
        ])
        let settings = PurposeModelSettings(defaults: defaults, catalog: catalog)
        settings.choose("here", for: .writing)
        #expect(WorkspaceStore.automaticFallback(settings)?.identifier == "gguf:" + file.path)
        settings.choose("gone", for: .writing)
        #expect(WorkspaceStore.automaticFallback(settings) == nil)
    }
}
