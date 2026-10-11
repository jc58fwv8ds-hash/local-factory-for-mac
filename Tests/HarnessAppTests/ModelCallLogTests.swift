import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

/// Backlog #41 (2026-10-11): every model request and answer is kept so it can be reconstructed later.
struct ModelCallLogTests {
    struct Echo: ModelInferenceProvider {
        func events(for request: InferenceRequest) async -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.yield("こん"); $0.yield("にちは"); $0.finish() }
        }
    }

    @Test func requestsAndAnswersAreAppendedAndOldFilesPruned() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("calls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("run.jsonl")
        let request = InferenceRequest(runtime: .ollama, modelIdentifier: "m",
                                       messages: [InferenceMessage(role: .user, content: "挨拶して")], maximumOutputTokens: 50)
        await ModelCallLog.$destination.withValue(file) {
            ModelCallLog.record(request, response: "こんにちは", error: nil, seconds: 1.23)
            ModelCallLog.record(request, response: nil, error: CancellationError(), seconds: 0)
        }
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let first = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(first["model"] as? String == "m" && first["response"] as? String == "こんにちは" && first["seconds"] as? Double == 1.2)
        #expect((first["messages"] as? [[String: String]])?.first?["content"] == "挨拶して")
        // Old daily files go after 14 days.
        let old = folder.appendingPathComponent("2026-01-01.jsonl")
        try "{}".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-20 * 86_400)], ofItemAtPath: old.path)
        ModelCallLog.prune(folder)
        #expect(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: file.path))
    }

    @Test func theAppsProviderPassesTheStreamThroughUnchanged() async throws {
        var text = ""
        for try await piece in await LoggingInferenceProvider(base: Echo()).events(for: InferenceRequest(
            runtime: .ollama, modelIdentifier: "m", messages: [InferenceMessage(role: .user, content: "x")])) { text += piece }
        #expect(text == "こんにちは")
    }
}
