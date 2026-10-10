import HarnessCore
import Testing
@testable import TaskOrchestrator

struct InferenceRouteTests {
    @Test func openAIPrefixSelectsTheOpenAICompatibleRuntime() {
        let routed = InferenceRoute.resolve("openai:qwen3.8-27b", default: .ollama)
        #expect(routed.runtime == .lmStudio && routed.model == "qwen3.8-27b")
        let plain = InferenceRoute.resolve("hf.co/lmstudio-community/Qwen3.8-27B-GGUF:Q4_K_M", default: .ollama)
        #expect(plain.runtime == .ollama && plain.model == "hf.co/lmstudio-community/Qwen3.8-27B-GGUF:Q4_K_M")
        let sampled = InferenceRoute.resolve("openai:qwen@t0.7", default: .ollama)
        #expect(sampled.runtime == .lmStudio && sampled.model == "qwen" && InferenceRoute.temperature("openai:qwen@t0.7") == 0.7)
        #expect(InferenceRoute.temperature("qwen3.6:35b-a3b-coding") == nil)
    }

    @Test func backburnerPrefixRoutesToTheAppManagedServer() {
        #expect(InferenceRoute.resolve("backburner:qwen3.8-27b-iq4xs", default: .ollama) == (.backburner, "qwen3.8-27b-iq4xs"))
        #expect(InferenceRoute.resolve("backburner:qwen3.8-27b-iq4xs@t0.7", default: .ollama) == (.backburner, "qwen3.8-27b-iq4xs"))
    }
}
