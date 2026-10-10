import Foundation

public enum InferenceStreamParser {
    public static func ollamaContent(from line: String) throws -> String? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = line.data(using: .utf8) else { return nil }
        let envelope = try JSONDecoder().decode(OllamaEnvelope.self, from: data)
        if let error = envelope.error, !error.isEmpty {
            throw InferenceError.serverError(statusCode: 200, message: error)
        }
        return envelope.message?.content
    }

    public static func openAIContent(from line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", !payload.isEmpty,
              let data = payload.data(using: .utf8) else { return nil }

        let envelope = try JSONDecoder().decode(OpenAIEnvelope.self, from: data)
        if let error = envelope.error?.message, !error.isEmpty {
            throw InferenceError.serverError(statusCode: 200, message: error)
        }
        return envelope.choices?.first?.delta.content
    }
}

private struct OllamaEnvelope: Decodable {
    struct Message: Decodable {
        let content: String?
    }

    let message: Message?
    let error: String?
}

private struct OpenAIEnvelope: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta
    }

    struct ErrorBody: Decodable {
        let message: String
    }

    let choices: [Choice]?
    let error: ErrorBody?
}
