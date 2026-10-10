import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

/// Per-purpose models (2026-10-09): writing and image use the model picked for them; the two lines are checked first.
@MainActor
struct PurposeModelTests {
    actor Recorder: ModelInferenceProvider {
        var models: [String] = []
        let reply: String
        init(reply: String) { self.reply = reply }
        func record(_ model: String) { models.append(model) }
        nonisolated func events(for request: InferenceRequest) async -> AsyncThrowingStream<String, Error> {
            await record(request.modelIdentifier)
            let reply = self.reply
            return AsyncThrowingStream { $0.yield(reply); $0.finish() }
        }
    }

    struct FakeImages: ImageGenerating {
        func generate(option: PurposeModelOption, prompt: String, output: URL) async throws {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("png".utf8).write(to: output)
        }
    }

    static let catalog = PurposeModelCatalog(
        writing: [PurposeModelOption(id: "w-large", label: "書く用", runtime: .ollama, model: "writer-large"),
                  PurposeModelOption(id: "w-check", label: "確かめ用", runtime: .ollama, model: "writer-check")],
        image: [PurposeModelOption(id: "img", label: "画像用", command: ["tool", "--prompt", "{prompt}", "--output", "{output}"])],
        roles: ["large": "w-large", "checker": "w-check"], codeRefusalFallback: "w-large")

    func makeStore(reply: String = "a calm lake at dawn") throws -> (WorkspaceStore, Recorder, UserDefaults) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("purpose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let repository = WorkspaceRepository(fileURL: base.appendingPathComponent("workspace.json"))
        var project = HarnessProject.starter
        project.selectedModel = ModelSelection(identifier: "project-model", displayName: "P", runtime: .ollama)
        try repository.saveLibrary(ProjectLibrary(records: [ProjectRecord(project: project)]))
        let recorder = Recorder(reply: reply)
        let store = WorkspaceStore(repository: repository, inferenceProvider: recorder)
        let defaults = UserDefaults(suiteName: "purpose-\(UUID().uuidString)")!
        store.purposeSettingsOverride = PurposeModelSettings(defaults: defaults, catalog: Self.catalog)
        store.imageGenerator = FakeImages()
        return (store, recorder, defaults)
    }

    @Test func writingUsesTheChosenModelAndConversationKeepsTheProjectModel() async throws {
        let (store, recorder, _) = try makeStore()
        store.purposeSettings.choose("w-large", for: .writing)
        store.composerPurpose = .writing
        store.instruction = "大人の恋愛小説の書き出しを書いて"
        store.submitInstruction()
        for _ in 0..<200 where await recorder.models.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await recorder.models.first == "writer-large")
        #expect(store.instruction.isEmpty)
    }

    @Test func aStoppedInstructionIsNotSentAndKeepsTheText() async throws {
        let (store, recorder, _) = try makeStore()
        store.composerPurpose = .writing
        store.instruction = "小学生の性的な話"
        store.submitInstruction()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.models.isEmpty)
        #expect(store.instruction == "小学生の性的な話")
    }

    @Test func anImageIsMadeWithTheLargeRoleWritingThePrompt() async throws {
        let (store, recorder, _) = try makeStore()
        store.purposeSettings.choose("w-check", for: .writing)   // roles still put the large role on w-large
        store.purposeSettings.choose("img", for: .image)
        store.composerPurpose = .image
        store.instruction = "夜明けの静かな湖"
        store.submitInstruction()
        var change: ImageChange?
        for _ in 0..<200 {
            change = store.imageChanges.values.first
            if case .ready = change?.status { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .ready(let url) = change?.status else { Issue.record("no image: \(String(describing: change?.status))"); return }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(change?.prompt == "a calm lake at dawn")
        #expect(await recorder.models == ["writer-large"])
        try? FileManager.default.removeItem(at: url)
    }

    @Test func noImageModelChosenSaysWhereToChooseOne() async throws {
        let (store, _, _) = try makeStore()
        store.composerPurpose = .image
        store.instruction = "夜明けの静かな湖"
        store.submitInstruction()
        for _ in 0..<200 {
            if case .failed = store.imageChanges.values.first?.status { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .failed(let message) = store.imageChanges.values.first?.status else { Issue.record("not failed"); return }
        #expect(message.contains("用途ごとのモデル"))
    }

    @Test func theLocalCatalogFileDecodesAndRefusalsAreRecognized() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("config/purpose-models.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let catalog = PurposeModelCatalog.load(from: file)
            #expect(!catalog.writing.isEmpty && !catalog.image.isEmpty)
            #expect(catalog.writing.allSatisfy { $0.selection != nil } && catalog.image.allSatisfy { $0.command != nil })
            #expect(catalog.option(id: catalog.codeRefusalFallback, for: .writing) != nil)
        }
        #expect(PurposeModelCatalog.load(from: URL(fileURLWithPath: "/dev/null")) == .empty)
        #expect(BackburnerServer.modelPath(from: "gguf:{home}/m.gguf") == FileManager.default.homeDirectoryForCurrentUser.path + "/m.gguf")
        #expect(BackburnerServer.modelPath(from: "qwen3.8-27b-iq4xs") == nil)
        #expect(ModelRefusal.looksLikeRefusal("申し訳ありませんが、その内容にはお応えできません。"))
        #expect(!ModelRefusal.looksLikeRefusal("{\"edits\": []}"))
        #expect(ImageGenerationService.arguments(["--prompt", "{prompt}", "--output", "{output}"], prompt: "lake",
                                                 output: URL(fileURLWithPath: "/tmp/a.png"), seed: 1) == ["--prompt", "lake", "--output", "/tmp/a.png"])
    }
}
