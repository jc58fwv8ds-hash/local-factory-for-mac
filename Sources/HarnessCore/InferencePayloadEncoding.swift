import Foundation

public enum InferencePayloadEncoder {
    /// `schemaInPrompt`: see the OpenAI-compatible case.
    public static func body(for request: InferenceRequest,
                            schemaInPrompt: Bool = ProcessInfo.processInfo.environment["HARNESS_OPENAI_SCHEMA_IN_PROMPT"] == "1") throws -> Data {
        guard VisualAttachmentPolicy.validationError(
            for: request.images.map(\.descriptor)
        ) == nil else {
            throw InferenceError.invalidVisualAttachments
        }
        let schema = request.structuredOutput.map(InferenceJSONSchema.init)
        let temperature = request.temperature ?? (request.structuredOutput == nil ? 0.25 : 0)
        switch request.runtime {
        case .ollama:
            return try JSONEncoder().encode(
                OllamaInferencePayload(
                    model: request.modelIdentifier,
                    messages: ollamaMessages(for: request),
                    stream: true,
                    think: false,
                    format: schema,
                    options: OllamaOptions(
                        numPredict: request.maximumOutputTokens,
                        temperature: temperature,
                        numCtx: request.minimumContextTokens
                    )
                )
            )
        case .lmStudio, .backburner:
            // A server without a grammar decoder (Strata, 2026-10-25) validates a response_format reply before sending any
            // of it: nothing streams, so the first-token watchdog cut off 4 of 30 tasks, and 4 more ended on its
            // "did not return valid JSON". With HARNESS_OPENAI_SCHEMA_IN_PROMPT=1 the schema goes into the prompt instead.
            // Strata never constrains output to a schema, whichever route reaches it.
            let toStrata = request.runtime == .backburner && request.modelIdentifier.hasPrefix(LocalInferenceService.strataPrefix)
            let schemaInPrompt = schema != nil && (schemaInPrompt && request.runtime == .lmStudio || toStrata)
            return try JSONEncoder().encode(
                OpenAIInferencePayload(
                    model: request.modelIdentifier,
                    messages: openAIMessages(for: request, schemaInstruction: schemaInPrompt ? try schema.map(schemaInstruction) : nil),
                    temperature: temperature,
                    stream: true,
                    maxTokens: request.maximumOutputTokens,
                    responseFormat: schemaInPrompt ? nil : schema.map(OpenAIResponseFormat.init)
                )
            )
        case .harness:
            throw InferenceError.unsupportedRuntime(.harness)
        }
    }

    private static func ollamaMessages(for request: InferenceRequest) -> [OllamaMessage] {
        let target = lastUserMessageIndex(in: request.messages)
        return request.messages.enumerated().map { index, message in
            OllamaMessage(
                role: message.role,
                content: message.content,
                images: index == target
                    ? request.images.map { $0.data.base64EncodedString() }
                    : nil
            )
        }
    }

    static func schemaInstruction(_ schema: InferenceJSONSchema) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(schema), as: UTF8.self)
        return "\n\nReply with exactly one JSON object that matches this JSON Schema, and nothing else (no code fence, "
            + "no text before or after it):\n" + text
    }

    private static func openAIMessages(for request: InferenceRequest, schemaInstruction: String? = nil) -> [OpenAIMessage] {
        let target = lastUserMessageIndex(in: request.messages)
        return request.messages.enumerated().map { index, message in
            let message = index == target && schemaInstruction != nil
                ? InferenceMessage(role: message.role, content: message.content + schemaInstruction!) : message
            guard index == target, !request.images.isEmpty else {
                return OpenAIMessage(role: message.role, content: .text(message.content))
            }
            let images = request.images.map {
                "data:\($0.descriptor.format.mimeType);base64,\($0.data.base64EncodedString())"
            }
            return OpenAIMessage(
                role: message.role,
                content: .multimodal(text: message.content, imageDataURLs: images)
            )
        }
    }

    private static func lastUserMessageIndex(in messages: [InferenceMessage]) -> Int? {
        messages.indices.last { messages[$0].role == .user }
    }
}

private struct OllamaInferencePayload: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let think: Bool
    let format: InferenceJSONSchema?
    let options: OllamaOptions
}

private struct OllamaMessage: Encodable {
    let role: InferenceMessage.Role
    let content: String
    let images: [String]?
}

private struct OllamaOptions: Encodable {
    let numPredict: Int
    let temperature: Double
    let numCtx: Int?

    enum CodingKeys: String, CodingKey {
        case numPredict = "num_predict"
        case temperature
        case numCtx = "num_ctx"
    }
}

private struct OpenAIInferencePayload: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let temperature: Double
    let stream: Bool
    let maxTokens: Int
    let responseFormat: OpenAIResponseFormat?
    /// Same as Ollama's `think: false`: llama-server chat templates (e.g. Qwen) otherwise emit reasoning first.
    /// Servers that do not know the field ignore it.
    let chatTemplateKwargs = ["enable_thinking": false]

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
        case chatTemplateKwargs = "chat_template_kwargs"
    }
}

private struct OpenAIMessage: Encodable {
    let role: InferenceMessage.Role
    let content: OpenAIMessageContent
}

private enum OpenAIMessageContent: Encodable {
    case text(String)
    case multimodal(text: String, imageDataURLs: [String])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .multimodal(let text, let urls):
            try container.encode(
                [OpenAIContentPart.text(text)] + urls.map(OpenAIContentPart.image)
            )
        }
    }
}

private struct OpenAIContentPart: Encodable {
    struct ImageURL: Encodable { let url: String }
    let type: String
    let text: String?
    let imageURL: ImageURL?

    static func text(_ text: String) -> OpenAIContentPart {
        OpenAIContentPart(type: "text", text: text, imageURL: nil)
    }

    static func image(_ url: String) -> OpenAIContentPart {
        OpenAIContentPart(type: "image_url", text: nil, imageURL: ImageURL(url: url))
    }

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }
}

private struct OpenAIResponseFormat: Encodable {
    let type = "json_schema"
    let jsonSchema: JSONSchemaBody

    init(schema: InferenceJSONSchema) {
        jsonSchema = JSONSchemaBody(schema: schema)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }

    struct JSONSchemaBody: Encodable {
        let name = "harness_response"
        let strict = true
        let schema: InferenceJSONSchema
    }
}
