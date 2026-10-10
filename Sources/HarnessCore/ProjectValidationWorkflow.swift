import Foundation

public enum ProjectValidationWorkflow {
    public static func completed(
        report: ProjectValidationReport,
        in project: inout HarnessProject
    ) {
        let succeeded = report.succeeded
        CreationLoopWorkflow.completedValidation(
            succeeded: succeeded,
            in: &project
        )
        let validationName = report.system == .xcode ? "Xcodeのビルドとテスト" : "ビルドとテスト"
        project.currentActivity = succeeded
            ? "\(validationName)に合格しました"
            : "検証結果を確認してください"
        project.activity.insert(
            ActivityEvent(
                title: succeeded ? "\(validationName)に合格しました" : "\(validationName)に失敗しました",
                detail: detail(for: report),
                kind: succeeded ? .verification : .warning
            ),
            at: 0
        )
    }

    private static func detail(for report: ProjectValidationReport) -> String {
        report.checks.map { check in
            "\(check.kind.displayName): \(check.succeeded ? "成功" : "失敗")（\(String(format: "%.1f", check.duration))秒）"
        }.joined(separator: " ・ ")
    }
}
