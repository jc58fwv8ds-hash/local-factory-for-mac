import Foundation

public enum ComputerOperationPolicy {
    private static let safeButtonWords = [
        "build", "run", "test", "refresh", "reload", "search", "continue", "resume",
        "ビルド", "実行", "テスト", "更新", "再読み込み", "検索", "続ける", "再開"
    ]

    public static func validate(
        _ step: ComputerOperationStep
    ) throws -> ComputerOperationStep {
        switch step.kind {
        case .projectValidation:
            return step
        case .webSearch:
            guard present(step.query) else {
                throw ComputerOperationPlanError.unsafeStep("検索する言葉がありません")
            }
        case .inspectApplication:
            guard present(step.application) else {
                throw ComputerOperationPlanError.unsafeStep("読み取るアプリが指定されていません")
            }
        case .pressButton:
            guard present(step.application), let element = step.element,
                  safeButtonWords.contains(where: {
                      element.localizedCaseInsensitiveContains($0)
                  }) else {
                throw ComputerOperationPlanError.unsafeStep(
                    "押せるのはBuild・Run・Test・Refresh・Search等の開発用ボタンだけです"
                )
            }
        }
        return step
    }

    private static func present(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
