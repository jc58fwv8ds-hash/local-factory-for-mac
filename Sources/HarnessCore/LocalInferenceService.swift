import Foundation

public actor LocalInferenceService: ModelInferenceProvider {
    private let session: URLSession

    public init() {
        self.session = LocalInferenceSessionPolicy.session()
    }

    public init(session: URLSession) {
        self.session = session
    }

    public func events(for request: InferenceRequest) async -> AsyncThrowingStream<String, Error> {
        let session = self.session

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try Self.makeURLRequest(for: request)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw InferenceError.invalidResponse
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        throw InferenceError.serverError(
                            statusCode: httpResponse.statusCode,
                            message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                        )
                    }

                    var receivedContent = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let content = try Self.content(from: line, runtime: request.runtime)
                        if let content, !content.isEmpty {
                            receivedContent = true
                            continuation.yield(content)
                        }
                    }

                    try Task.checkCancellation()
                    guard receivedContent else { throw InferenceError.emptyResponse }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as InferenceError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    continuation.finish(
                        throwing: InferenceError.connectionFailed(
                            request.runtime,
                            error.localizedDescription
                        )
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func content(from line: String, runtime: RuntimeKind) throws -> String? {
        switch runtime {
        case .ollama:
            try InferenceStreamParser.ollamaContent(from: line)
        case .lmStudio, .backburner:
            try InferenceStreamParser.openAIContent(from: line)
        case .harness:
            throw InferenceError.unsupportedRuntime(.harness)
        }
    }

    public static let backburnerChatURL = "http://127.0.0.1:8080/v1/chat/completions"
    /// The light-job helper Mac's small model, forwarded to this port over SSH by the app (HelperNode, 2026-10-18).
    public static let helperChatURL = "http://127.0.0.1:18081/v1/chat/completions"
    /// The 125B MoE on Strata (2026-10-25), started by the App in place of the 27B: model identifiers "strata:<config>".
    public static let strataChatURL = "http://127.0.0.1:8090/v1/chat/completions"
    public static let strataPrefix = "strata:"

    private static func makeURLRequest(for request: InferenceRequest) throws -> URLRequest {
        let url: URL
        let body = try InferencePayloadEncoder.body(for: request)

        switch request.runtime {
        case .ollama:
            url = URL(string: "http://127.0.0.1:11434/api/chat")!
        case .lmStudio:
            // LM Studio by default; another local OpenAI-compatible server (e.g. llama-server) via the environment.
            url = ProcessInfo.processInfo.environment["HARNESS_OPENAI_COMPATIBLE_URL"].flatMap(URL.init(string:))
                ?? URL(string: "http://127.0.0.1:1234/v1/chat/completions")!
        case .backburner:
            url = URL(string: request.modelIdentifier.hasPrefix("helper:") ? Self.helperChatURL
                : request.modelIdentifier.hasPrefix(Self.strataPrefix) ? Self.strataChatURL : Self.backburnerChatURL)!
        case .harness:
            throw InferenceError.unsupportedRuntime(.harness)
        }

        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        return urlRequest
    }
}
