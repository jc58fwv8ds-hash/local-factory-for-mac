import Foundation

/// An editable reply draft, never an execution plan or permission grant.
public struct ReplySuggestion: Identifiable, Equatable, Sendable {
    public static let maximumCount = 2
    public static let maximumTitleCharacters = 32
    public static let maximumInstructionCharacters = 200
    public static let maximumEffectCharacters = 100
    public static let maximumResponseCharacters = 8_000

    public let id: UUID
    public let title: String
    public let instruction: String
    public let effect: String

    public init(id: UUID = UUID(), title: String, instruction: String, effect: String) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.effect = effect
    }
}

public enum ReplySuggestionError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case responseTooLong
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidResponse, .responseTooLong:
            "候補を読みやすい形にまとめられませんでした。もう一度試すか、そのまま自分の言葉で頼んでね。"
        case .timedOut:
            "候補づくりに時間がかかったので止めました。そのまま自分の言葉で頼むこともできるよ。"
        }
    }
}

public enum ReplySuggestionResponseParser {
    private struct Payload: Decodable {
        let suggestions: [Entry]
    }

    private struct Entry: Decodable {
        let title: String
        let instruction: String
        let effect: String
    }

    public static func suggestions(from response: String) throws -> [ReplySuggestion] {
        guard response.count <= ReplySuggestion.maximumResponseCharacters,
              let data = StructuredModelResponse.jsonText(from: response).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              (2...ReplySuggestion.maximumCount).contains(payload.suggestions.count) else {
            throw ReplySuggestionError.invalidResponse
        }
        var titles = Set<String>()
        var instructions = Set<String>()
        return try payload.suggestions.map { entry in
            let title = try text(entry.title, limit: ReplySuggestion.maximumTitleCharacters)
            let instruction = try text(entry.instruction, limit: ReplySuggestion.maximumInstructionCharacters)
            let effect = try text(entry.effect, limit: ReplySuggestion.maximumEffectCharacters)
            guard titles.insert(title.lowercased()).inserted,
                  instructions.insert(instruction.lowercased()).inserted else {
                throw ReplySuggestionError.invalidResponse
            }
            return ReplySuggestion(title: title, instruction: instruction, effect: effect)
        }
    }

    private static func text(_ raw: String, limit: Int) throws -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard !cleaned.isEmpty, cleaned.count <= limit,
              cleaned.rangeOfCharacter(from: forbidden) == nil else {
            throw ReplySuggestionError.invalidResponse
        }
        return cleaned
    }
}
