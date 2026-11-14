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
            // The look at a finished picture passes, so a picture is not made again (2026-11-14).
            let reply = request.messages.last?.content.contains("MATCH: YES only if") == true ? "MATCH: YES" : self.reply
            return AsyncThrowingStream { $0.yield(reply); $0.finish() }
        }
    }

    struct FakeImages: ImageGenerating {
        func generate(option: PurposeModelOption, prompt: String, output: URL, options: ImageGenerationOptions) async throws {
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
        store.workspaceMode = .chat   // purposes are chat-mode only (2026-10-19)
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
        // The same writer, then asked whether the prompt kept everything the words asked for, then where the scene is (2026-11-14).
        #expect(await recorder.models == ["writer-large", "writer-large", "writer-large", "writer-large"])  // and the check of the picture
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("json"))
    }

    /// A follow-up on an image starts from its prompt and seed (2026-11-04), and the check counts the earlier instructions.
    @Test func aFollowUpBuildsOnTheLastImageAndTheCheckSeesTheEarlierInstruction() async throws {
        let (store, recorder, _) = try makeStore(reply: "EDIT: a calm red lake")
        store.purposeSettings.choose("img", for: .image)
        store.composerPurpose = .image
        store.instruction = "夜明けの静かな湖"
        store.submitInstruction()
        func ready(_ count: Int) async throws {
            for _ in 0..<200 {
                let done = store.imageChanges.values.filter { if case .ready = $0.status { true } else { false } }
                if done.count == count { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("not ready: \(count)")
        }
        try await ready(1)
        let first = try #require(store.imageChanges.values.first)
        store.instruction = "もっと赤くして"
        store.submitInstruction()
        try await ready(2)
        let second = try #require(store.imageChanges.values.first { $0.id != first.id })
        #expect(second.prompt == "a calm red lake" && second.seed == first.seed)

        store.instruction = "小学生の写真"
        store.submitInstruction()
        try await ready(3)
        store.instruction = "裸にして"
        store.submitInstruction()
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.instruction == "裸にして")   // stopped: the earlier instruction counts
        #expect(store.imageChanges.count == 3)
        _ = recorder
        for change in store.imageChanges.values { if case .ready(let url) = change.status { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("json")) } }
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

    @Test func personKeepingModelWithoutPictureFallsBackToPlainModel() {
        let keep = PurposeModelOption(id: "keep", label: "人物を保つ", command: ["keep", "--image", "{image}", "--output", "{output}"])
        let plain = PurposeModelOption(id: "plain", label: "ふつう", command: ["tool", "--output", "{output}"])
        let catalog = PurposeModelCatalog(writing: [], image: [keep, plain])
        #expect(catalog.pictureModel(keep, hasPicture: false).id == "plain")
        #expect(catalog.pictureModel(keep, hasPicture: true).id == "keep")
        #expect(catalog.pictureModel(plain, hasPicture: false).id == "plain")
        #expect(catalog.pictureModel(plain, hasPicture: true).id == "plain")
        #expect(catalog.pictureModel(plain, hasPicture: true, keepsPerson: true).id == "keep")
        #expect(GeneratedMedia.namesPerson("画像の人物がネオン瞬く夜の香港で石段に腰掛けている様子を生成"))
        #expect(!GeneratedMedia.namesPerson("背景を青くして"))
        // In a chat, a request works on the last picture unless it starts anew; 「最初の画像で」 takes the first (2026-11-14).
        let notes = ["画像ができました。保存先: /tmp/a-first.png", "動画ができました。保存先: /tmp/b.mp4", "画像ができました。保存先: /tmp/c-last.png"]
        #expect(GeneratedMedia.workingPicture(for: "通行人がいる東京駅の正面入り口をまっすぐ歩かせて", in: notes, exists: { _ in true })?.lastPathComponent == "c-last.png")
        #expect(GeneratedMedia.workingPicture(for: "最初の画像で海辺を歩かせて", in: notes, exists: { _ in true })?.lastPathComponent == "a-first.png")
        #expect(GeneratedMedia.workingPicture(for: "新しい女性が海辺を歩く動画", in: notes, exists: { _ in true }) == nil)
    }
}
