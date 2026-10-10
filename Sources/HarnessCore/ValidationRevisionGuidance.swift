import Foundation

public struct ValidationRevisionGuidance: Equatable, Sendable {
    public let currentState: String
    public let proposedChange: String
    public let expectedResult: String

    public init(
        currentState: String,
        proposedChange: String,
        expectedResult: String
    ) {
        self.currentState = currentState
        self.proposedChange = proposedChange
        self.expectedResult = expectedResult
    }
}

public enum ValidationRevisionGuidanceBuilder {
    public static func make(
        report: ProjectValidationReport,
        analysis: BuildFailureAnalysis?
    ) -> ValidationRevisionGuidance {
        if report.succeeded {
            return ValidationRevisionGuidance(
                currentState: "実行したビルドとテストはすべて合格しています。",
                proposedChange: "要件どおりの操作結果かを確認し、必要なら境界条件のテストを追加します。問題がなければ完成として終了できます。",
                expectedResult: "動くだけでなく、変更後も壊れにくい成果物として完成判断できます。"
            )
        }

        let failedNames = report.checks
            .filter { !$0.succeeded }
            .map { $0.kind.displayName }
            .joined(separator: "、")
        let assessment = ValidationFailureClassifier.classify(
            report: report,
            analysis: analysis
        )
        if !assessment.permitsCodeChanges {
            return ValidationRevisionGuidance(
                currentState: "\(failedNames)が失敗しています。\(assessment.title)。",
                proposedChange: assessment.nextAction,
                expectedResult: "実行環境を先に整えることで、不要なコード変更を避け、残った実装上の問題だけを安全に切り分けられます。"
            )
        }
        let targetDescription = analysis?.repairPlan?.targets.prefix(3).map { target in
            target.relativePath
        }.joined(separator: "、")
        let diagnostic = analysis?.primaryDiagnostic?.message
        let current = diagnostic.map {
            "\(failedNames)が失敗しています。最初に確認できた原因は「\($0)」です。"
        } ?? "\(failedNames)が失敗しています。出力から安全に編集できる対象を特定できていません。"
        let proposed = targetDescription.flatMap { $0.isEmpty ? nil : $0 }.map {
            "まず\($0)を対象に、診断された問題だけを小さく修正してから再検証します。"
        } ?? "検証出力と接続ソースを照合し、対象ファイルを特定してから修正します。"

        return ValidationRevisionGuidance(
            currentState: current,
            proposedChange: proposed,
            expectedResult: "原因ごとに変更範囲を限定することで、既存動作への影響を抑えながらビルドとテストの合格を目指せます。"
        )
    }
}
