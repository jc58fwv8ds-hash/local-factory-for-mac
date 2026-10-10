import Foundation

public protocol ReplySuggestionProviding: Sendable {
    func suggestions(for context: ReplySuggestionContext) async throws -> [ReplySuggestion]
}

/// Optional local inference, separate from production and conversational state transitions.
public struct ReplySuggestionService: ReplySuggestionProviding {
    private let inference: any ModelInferenceProvider
    private let timeout: Duration

    public init(inference: any ModelInferenceProvider, timeout: Duration = .seconds(90)) {
        self.inference = inference
        self.timeout = min(max(timeout, .milliseconds(1)), .seconds(90))
    }

    public func suggestions(for context: ReplySuggestionContext) async throws -> [ReplySuggestion] {
        try Task.checkCancellation()
        let request = InferenceRequest(
            runtime: context.model.runtime, modelIdentifier: context.model.identifier,
            messages: ReplySuggestionPromptBuilder.messages(for: context),
            maximumOutputTokens: InferenceOutputBudget.replySuggestions,
            structuredOutput: .replySuggestions
        )
        let result = try await withThrowingTaskGroup(of: [ReplySuggestion].self) { group in
            group.addTask { [inference] in
                var response = ""
                for try await fragment in await inference.events(for: request) {
                    try Task.checkCancellation()
                    guard response.count + fragment.count <= ReplySuggestion.maximumResponseCharacters else {
                        throw ReplySuggestionError.responseTooLong
                    }
                    response += fragment
                }
                try Task.checkCancellation()
                return try ReplySuggestionResponseParser.suggestions(from: response)
            }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw ReplySuggestionError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
        try Task.checkCancellation()
        return result
    }
}
