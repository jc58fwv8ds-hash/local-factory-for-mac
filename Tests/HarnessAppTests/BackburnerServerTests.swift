import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

struct BackburnerServerTests {
    @Test func wiredLimitIsRequestedOnlyWhenTooLowOnSmallMacs() {
        #expect(BackburnerServer.wiredLimitToRequest(memoryMB: 32768, currentLimitMB: 21504) == 28672)
        #expect(BackburnerServer.wiredLimitToRequest(memoryMB: 32768, currentLimitMB: 28672) == nil)   // already raised
        #expect(BackburnerServer.wiredLimitToRequest(memoryMB: 65536, currentLimitMB: 0) == nil)       // large Macs: never
    }

    @Test func otherRuntimesPassThroughWithoutStartingBackburner() async throws {
        actor Recorder: ModelInferenceProvider {
            var runtimes: [RuntimeKind] = []
            func events(for request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
                runtimes.append(request.runtime)
                return AsyncThrowingStream { $0.yield("ok"); $0.finish() }
            }
        }
        let recorder = Recorder()
        let provider = BackburnerAwareInferenceProvider(base: recorder)
        var text = ""
        for try await part in await provider.events(for: InferenceRequest(runtime: .ollama, modelIdentifier: "m",
                                                                         messages: [.init(role: .user, content: "hi")])) {
            text += part
        }
        #expect(text == "ok")
        #expect(await recorder.runtimes == [.ollama])
    }

    @Test func backburnerRuntimeUsesTheOpenAICompatibleEndpoint() throws {
        let request = InferenceRequest(runtime: .backburner, modelIdentifier: "q",
            messages: [.init(role: .user, content: "hi")], maximumOutputTokens: 600)
        let json = try #require(try JSONSerialization.jsonObject(with: InferencePayloadEncoder.body(for: request)) as? [String: Any])
        #expect(json["max_tokens"] as? Int == request.maximumOutputTokens)
        #expect((json["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
        #expect(LocalInferenceService.backburnerChatURL == "http://127.0.0.1:8080/v1/chat/completions")
    }

    /// Real start → request → stop against the installed Backburner. Opt-in: HARNESS_BACKBURNER_LIVE=1 (needs ~/backburner,
    /// no other server on 8080, and the wired limit already raised or a person at the keyboard for the password dialog).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_BACKBURNER_LIVE"] == "1"))
    func liveStartAnswerAndStop() async throws {
        try await BackburnerServer.shared.ensureRunning()
        let provider = BackburnerAwareInferenceProvider(base: LocalInferenceService())
        var text = ""
        for try await part in await provider.events(for: InferenceRequest(runtime: .backburner, modelIdentifier: "qwen",
            messages: [.init(role: .user, content: "Reply with the single word: ready")], maximumOutputTokens: 64)) { text += part }
        #expect(text.lowercased().contains("ready"), "\(text)")
        await BackburnerServer.shared.stop()
        try await Task.sleep(for: .seconds(5))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8080/health")!); request.timeoutInterval = 2
        #expect((try? await URLSession.shared.data(for: request)) == nil, "server still answering after stop")
    }
}
