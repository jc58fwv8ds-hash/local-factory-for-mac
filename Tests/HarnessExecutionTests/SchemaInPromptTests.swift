import Foundation
import HarnessCore
import Testing

struct SchemaInPromptTests {
    private func body(_ runtime: RuntimeKind, schemaInPrompt: Bool, model: String = "m") throws -> [String: Any] {
        let request = InferenceRequest(runtime: runtime, modelIdentifier: model, messages: [.init(role: .user, content: "hi")],
            maximumOutputTokens: 512, structuredOutput: .fileContent)
        return try JSONSerialization.jsonObject(with: InferencePayloadEncoder.body(for: request, schemaInPrompt: schemaInPrompt)) as! [String: Any]
    }

    private func lastContent(_ body: [String: Any]) -> String {
        ((body["messages"] as! [[String: Any]]).last!["content"] as! String)
    }

    @Test func schemaMovesIntoThePromptForAnOpenAICompatibleServer() throws {
        let moved = try body(.lmStudio, schemaInPrompt: true)
        #expect(moved["response_format"] == nil)
        #expect(lastContent(moved).hasPrefix("hi\n\nReply with exactly one JSON object"))
        #expect(lastContent(moved).contains(#""required":["content"]"#))
    }

    @Test func responseFormatStaysByDefaultAndForBackburner() throws {
        #expect(try body(.lmStudio, schemaInPrompt: false)["response_format"] != nil)
        let backburner = try body(.backburner, schemaInPrompt: true)
        #expect(backburner["response_format"] != nil)
        #expect(lastContent(backburner) == "hi")
    }

    @Test func strataAlwaysGetsTheSchemaInThePrompt() throws {
        let strata = try body(.backburner, schemaInPrompt: false, model: "strata:{home}/Strata/strata-q2_0-m4.json")
        #expect(strata["response_format"] == nil)
        #expect(lastContent(strata).contains("Reply with exactly one JSON object"))
    }
}
