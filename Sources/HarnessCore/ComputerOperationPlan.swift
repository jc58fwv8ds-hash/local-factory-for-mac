import Foundation

public enum ComputerOperationKind: String, Codable, CaseIterable, Sendable {
    case projectValidation
    case webSearch
    case inspectApplication
    case pressButton

    public var displayName: String {
        switch self {
        case .projectValidation: "プロジェクトのビルドとテスト"
        case .webSearch: "Web検索を開く"
        case .inspectApplication: "アプリ画面を読み取る"
        case .pressButton: "アプリの安全なボタンを押す"
        }
    }

    public var systemImage: String {
        switch self {
        case .projectValidation: "checkmark.seal"
        case .webSearch: "magnifyingglass"
        case .inspectApplication: "eye"
        case .pressButton: "cursorarrow.click"
        }
    }
}

public struct ComputerOperationStep: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: ComputerOperationKind
    public let query: String?
    public let application: String?
    public let element: String?
    public let reason: String

    public init(
        id: UUID = UUID(),
        kind: ComputerOperationKind,
        query: String? = nil,
        application: String? = nil,
        element: String? = nil,
        reason: String
    ) {
        self.id = id
        self.kind = kind
        self.query = query
        self.application = application
        self.element = element
        self.reason = reason
    }

    public var detail: String {
        switch kind {
        case .projectValidation: reason
        case .webSearch: "「\(query ?? "")」を検索 — \(reason)"
        case .inspectApplication: "\(application ?? "アプリ") — \(reason)"
        case .pressButton:
            "\(application ?? "アプリ")の「\(element ?? "ボタン")」 — \(reason)"
        }
    }
}

public struct ComputerOperationPlan: Codable, Equatable, Sendable {
    public static let maximumSteps = 6

    public let summary: String
    public let steps: [ComputerOperationStep]

    public init(summary: String, steps: [ComputerOperationStep]) {
        self.summary = summary
        self.steps = Array(steps.prefix(Self.maximumSteps))
    }
}

public enum ComputerOperationPlanError: LocalizedError, Equatable, Sendable {
    case instructionMissing
    case invalidResponse
    case unsafeStep(String)

    public var errorDescription: String? {
        switch self {
        case .instructionMissing: "コンピュータへ頼む内容を入力してください。"
        case .invalidResponse: "操作案を安全な形式として読み取れませんでした。もう一度お試しください。"
        case let .unsafeStep(message): "安全のため操作案を止めました：\(message)"
        }
    }
}

public enum ComputerOperationPromptBuilder {
    public static func messages(
        instruction: String,
        project: HarnessProject,
        hasSource: Bool
    ) throws -> [InferenceMessage] {
        let cleaned = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ComputerOperationPlanError.instructionMissing }
        let system = """
        あなたはHarnessの安全なComputer Operator計画担当です。
        ユーザーの普段の日本語を、許可された操作だけで最大\(ComputerOperationPlan.maximumSteps)手順へ整理してください。
        許可するkindは projectValidation, webSearch, inspectApplication, pressButton だけです。
        projectValidationは接続ソースをbuildし、テストがあれば実行します。
        webSearchは既定ブラウザで検索を開きます。queryが必要です。
        inspectApplicationは実行中アプリのアクセシビリティ情報を読みます。applicationが必要です。
        pressButtonはBuild、Run、Test、Refresh、Search等の安全なボタンだけを押します。applicationとelementが必要です。
        文字入力、削除、購入、送信、公開、ログイン、権限変更、契約への同意は計画しないでください。
        実行前にユーザーが全手順を確認するので、reasonを普段の日本語で具体的に書いてください。
        JSON以外は返さないでください。
        """
        let user = """
        プロジェクト: \(project.name)
        現在の作業: \(project.currentActivity)
        接続ソース: \(hasSource ? "あり" : "なし")
        ユーザーの依頼: \(cleaned)
        """
        return [
            InferenceMessage(role: .system, content: system),
            InferenceMessage(role: .user, content: user)
        ]
    }
}

public enum ComputerOperationPlanParser {
    private struct Payload: Decodable {
        let summary: String
        let steps: [StepPayload]
    }

    private struct StepPayload: Decodable {
        let kind: ComputerOperationKind
        let query: String?
        let application: String?
        let element: String?
        let reason: String
    }

    public static func parse(_ response: String) throws -> ComputerOperationPlan {
        let json = StructuredModelResponse.jsonText(from: response)
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.steps.isEmpty,
              payload.steps.count <= ComputerOperationPlan.maximumSteps else {
            throw ComputerOperationPlanError.invalidResponse
        }
        let steps = try payload.steps.map { payload in
            try ComputerOperationPolicy.validate(
                ComputerOperationStep(
                    kind: payload.kind,
                    query: bounded(payload.query),
                    application: bounded(payload.application),
                    element: bounded(payload.element),
                    reason: bounded(payload.reason) ?? "必要な確認を行います"
                )
            )
        }
        return ComputerOperationPlan(
            summary: String(payload.summary.prefix(400)),
            steps: steps
        )
    }

    private static func bounded(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(300))
    }
}
