import Foundation
import HarnessCore

enum ValidationResultPolicy {
    static func normalize(_ report: ProjectValidationReport, requireTests: Bool) -> ProjectValidationReport {
        var checks = report.checks.map { check in
            guard isTest(check), check.succeeded,
                  !showsExecutedTests(check.output) else { return check }
            return ProjectValidationCheck(
                kind: check.kind, succeeded: false, exitCode: check.exitCode,
                output: check.output + "\n[Harness] 1件以上のテスト完了を確認できないため、合格として扱いません。",
                outputWasTruncated: check.outputWasTruncated, duration: check.duration
            )
        }
        if !checks.contains(where: isBuild) {
            checks.append(missing(.build, "ビルド結果を受け取れませんでした。"))
        }
        if requireTests, !checks.contains(where: isTest) {
            checks.append(missing(.test, "この作業にはテストが必要ですが、テストの実行結果がありません。"))
        }
        // An exit code cannot be overruled by a provider's optimistic success flag.
        checks = checks.map { check in
            ProjectValidationCheck(
                kind: check.kind, succeeded: check.succeeded && check.exitCode == 0,
                exitCode: check.exitCode, output: check.output,
                outputWasTruncated: check.outputWasTruncated, duration: check.duration
            )
        }
        return ProjectValidationReport(startedAt: report.startedAt, finishedAt: report.finishedAt,
                                       checks: checks, artifacts: report.artifacts)
    }

    static func showsExecutedTests(_ output: String) -> Bool {
        output.range(of: #"(?:Executed|Test run with) [1-9][0-9]* tests?\b"#, options: .regularExpression) != nil
            || output.range(of: #"Test [Cc]ase .+ passed \("#, options: .regularExpression) != nil
    }

    static func isBuild(_ check: ProjectValidationCheck) -> Bool { check.kind == .build || check.kind == .xcodeBuild }
    static func isTest(_ check: ProjectValidationCheck) -> Bool { check.kind == .test || check.kind == .xcodeTest }

    private static func missing(_ kind: ProjectValidationKind, _ message: String) -> ProjectValidationCheck {
        ProjectValidationCheck(kind: kind, succeeded: false, exitCode: 1, output: "[Harness] \(message)",
                               outputWasTruncated: false, duration: 0)
    }
}
