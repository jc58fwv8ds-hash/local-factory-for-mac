import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

/// The 125B writing option end to end (2026-10-25): the App's provider starts Strata in place of the 27B, answers plain
/// and schema-bound requests, and the next 27B request stops Strata again. HARNESS_STRATA_LIVE=1, no Backburner running.
/// Serialized: both tests drive the one shared Strata process, which answers one request at a time.
@Suite(.serialized)
struct StrataLiveTests {
    private func text(_ request: InferenceRequest) async throws -> String {
        var out = ""
        for try await piece in await BackburnerAwareInferenceProvider(base: LocalInferenceService()).events(for: request) { out += piece }
        return out
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_STRATA_LIVE"] != nil), .timeLimit(.minutes(20)))
    func swapsTheModelsAndAnswers() async throws {
        let model = "strata:{home}/Strata/strata-q2_0-m4.json"
        let plain = try await text(.init(runtime: .backburner, modelIdentifier: model,
                                         messages: [.init(role: .user, content: "日本の首都を一語で。")], maximumOutputTokens: 16))
        print("125B: \(plain)")
        #expect(plain.contains("東京"))
        let json = try await text(.init(runtime: .backburner, modelIdentifier: model,
                                        messages: [.init(role: .user, content: "content に「こんにちは」と入れて返して。")],
                                        maximumOutputTokens: 64, structuredOutput: .fileContent))
        print("125B JSON: \(json)")
        let object = try JSONSerialization.jsonObject(with: Data(StructuredResponseText.jsonObject(in: json).utf8)) as? [String: Any]
        #expect((object?["content"] as? String)?.contains("こんにちは") == true)
        #expect(await StrataServer.shared.isRunning)

        let back = try await text(.init(runtime: .backburner, modelIdentifier: "qwen", messages: [.init(role: .user, content: "1+1=?")],
                                        maximumOutputTokens: 8))
        print("27B: \(back)")
        #expect(!(await StrataServer.shared.isRunning))
        let strataPort = Process()
        strataPort.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        strataPort.arguments = ["-z", "-G", "1", "127.0.0.1", "8090"]
        try strataPort.run(); strataPort.waitUntilExit()
        #expect(strataPort.terminationStatus != 0)
        await BackburnerServer.shared.stop()
    }

    /// The way the composer sends it: chat mode, 文章を書く, the 125B picked from the local catalog (config/purpose-models.json).
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_STRATA_LIVE"] != nil), .timeLimit(.minutes(20)))
    func theComposerWritesWithThe125B() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("config/purpose-models.json")
        let catalog = PurposeModelCatalog.load(from: file)
        try #require(catalog.option(id: "qwen38-flash-next-125b", for: .writing) != nil)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("strata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let repository = WorkspaceRepository(fileURL: base.appendingPathComponent("workspace.json"))
        try repository.saveLibrary(ProjectLibrary(records: [ProjectRecord(project: HarnessProject.starter)]))
        let store = WorkspaceStore(repository: repository, inferenceProvider: BackburnerAwareInferenceProvider(base: LocalInferenceService()))
        store.workspaceMode = .chat
        store.purposeSettingsOverride = PurposeModelSettings(defaults: UserDefaults(suiteName: "strata-\(UUID().uuidString)")!, catalog: catalog)
        store.purposeSettings.choose("qwen38-flash-next-125b", for: .writing)
        store.composerPurpose = .writing
        store.instruction = "秋の夕暮れを題材にした三行の詩を書いて。"
        store.submitInstruction()
        let started = Date()
        while Date().timeIntervalSince(started) < 600 {
            if !store.isGenerating, store.project.conversation.last?.role == .assistant { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let reply = store.project.conversation.last
        print("125B(画面と同じ経路、\(Int(Date().timeIntervalSince(started))) 秒): \(reply?.content ?? "なし")")
        #expect(reply?.role == .assistant)
        #expect((reply?.content.count ?? 0) > 10)
        #expect(await StrataServer.shared.isRunning)
        await StrataServer.shared.stop()
    }
}

