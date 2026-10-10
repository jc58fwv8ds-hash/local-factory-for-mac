import Foundation
import HarnessCore
import Testing

struct InferenceContextWindowTests {
    private func options(_ request: InferenceRequest) throws -> [String: Any] {
        let body = try JSONSerialization.jsonObject(with: InferencePayloadEncoder.body(for: request)) as! [String: Any]
        return body["options"] as! [String: Any]
    }

    @Test func defaultRequestKeepsRuntimeContextWindow() throws {
        let request = InferenceRequest(runtime: .ollama, modelIdentifier: "m", messages: [.init(role: .user, content: "hi")])
        #expect(try options(request)["num_ctx"] == nil)
    }

    @Test func explicitMinimumContextIsSentToOllama() throws {
        let request = InferenceRequest(runtime: .ollama, modelIdentifier: "m", messages: [.init(role: .user, content: "hi")],
            maximumOutputTokens: 512, structuredOutput: .coveragePlan, minimumContextTokens: 16_384)
        let values = try options(request)
        #expect(values["num_ctx"] as? Int == 16_384)
        #expect(values["num_predict"] as? Int == 512)
    }
}
