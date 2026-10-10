import Foundation

public struct InferenceMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct InferenceImage: Equatable, Sendable {
    public let descriptor: VisualAttachmentDescriptor
    public let data: Data
    public let recognizedText: VisualTextTranscript?

    public init?(
        descriptor: VisualAttachmentDescriptor,
        data: Data,
        recognizedText: VisualTextTranscript? = nil
    ) {
        guard descriptor.byteCount == data.count,
              descriptor.contentHash == VisualContentHash.sha256Hex(of: data),
              VisualAttachmentPolicy.validationError(for: descriptor) == nil else {
            return nil
        }
        self.descriptor = descriptor
        self.data = data
        self.recognizedText = recognizedText?.attachmentID == descriptor.id
            ? recognizedText
            : nil
    }
}

public struct InferenceRequest: Equatable, Sendable {
    public let runtime: RuntimeKind
    public let modelIdentifier: String
    public let messages: [InferenceMessage]
    public let maximumOutputTokens: Int
    public let structuredOutput: InferenceStructuredOutput?
    public let images: [InferenceImage]
    /// Minimum runtime context window. nil keeps the runtime default (app behaviour
    /// unchanged); Ollama otherwise silently truncates prompts beyond its default.
    public let minimumContextTokens: Int?
    /// Sampling temperature; nil keeps the defaults (0 for structured output, 0.25 for conversation).
    public let temperature: Double?

    public init(
        runtime: RuntimeKind,
        modelIdentifier: String,
        messages: [InferenceMessage],
        maximumOutputTokens: Int = InferenceOutputBudget.conversation,
        structuredOutput: InferenceStructuredOutput? = nil,
        images: [InferenceImage] = [],
        minimumContextTokens: Int? = nil,
        temperature: Double? = nil
    ) {
        self.runtime = runtime
        self.modelIdentifier = modelIdentifier
        self.messages = messages
        self.maximumOutputTokens = InferenceOutputBudget.bounded(maximumOutputTokens)
        self.structuredOutput = structuredOutput
        self.images = images
        self.minimumContextTokens = minimumContextTokens
        self.temperature = temperature
    }
}

public enum InferenceError: LocalizedError, Equatable, Sendable {
    case unsupportedRuntime(RuntimeKind)
    case invalidResponse
    case serverError(statusCode: Int, message: String)
    case connectionFailed(RuntimeKind, String)
    case emptyResponse
    case repeatedResponse
    case unchangedRephrase
    case responseSentenceCount(expected: Int, actual: Int)
    case invalidVisualAttachments

    public var errorDescription: String? {
        switch self {
        case .unsupportedRuntime(let runtime):
            "\(runtime.rawValue)はまだ推論に対応していません。"
        case .invalidResponse:
            "AIランタイムから認識できない応答が返されました。"
        case .serverError(let statusCode, let message):
            "AIランタイムがエラーを返しました（\(statusCode)）：\(message)"
        case .connectionFailed(let runtime, let detail):
            "\(runtime.rawValue)へ接続できませんでした。サーバーを起動してください。\(detail)"
        case .emptyResponse:
            "AIモデルから本文を受け取れませんでした。"
        case .repeatedResponse:
            "考え直しても前と同じ返答だったため、新しい提案として保存していません。次に具体化したい点をひとつ教えてね。"
        case .unchangedRephrase:
            "言い直しを1回試しましたが、前と同じ文章だったため保存していません。変えたい言葉や雰囲気をもう少し教えてね。"
        case .responseSentenceCount(let expected, let actual):
            "AIが指定の\(expected)文にまとめられず、\(actual)文のままだったため、この返答は保存していません。もう一度頼んでね。"
        case .invalidVisualAttachments:
            "画像の数・容量・形式を確認できないため、AIへ送りませんでした。"
        }
    }
}

public protocol ModelInferenceProvider: Sendable {
    func events(for request: InferenceRequest) async -> AsyncThrowingStream<String, Error>
}
