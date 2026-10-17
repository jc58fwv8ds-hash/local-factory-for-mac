import Foundation
import HarnessCore
import HarnessExecution

/// The task description, the entry point and the small failure helpers of TaskOrchestrator (split out 2026-10-18 to keep
/// each source file under the architecture check's 350 lines).
extension TaskOrchestrator {
    struct Task: Codable {
        let objective: String
        let allowedFiles: [String]?
        let protectedFiles: [String]
        let appendOnly: [String]
        let maxEdits: Int
        let maxLines: Int
        /// "package" (default since 2026-10-05, plan 0005): every `Sources/` file is editable from the start when the package
        /// fits the prompt budget; "selector": the ContextSelector scope with target discovery and promotion.
        var scopeMode: String?
        /// Examiner check after the tests pass (BatchExaminerStage). Off by default since 2026-10-08: on C2 and suite-b5 it added
        /// 45-65% time without a net gain; opt in with true (runner `--examiner`).
        var examinerCheck: Bool?
        /// Example check for the user after the tests pass (ExampleCheckStage, 2026-10-09; the app turns it on).
        var exampleCheck: Bool?
        /// true: the examiner and the example check run only when RiskSignals flag the change (about a third of the changes,
        /// half of the false successes). The measured suites leave it off so `--examiner` keeps checking every task.
        var gatedChecks: Bool?
        /// Output-token limit of the proposal call (default 2048); larger edits from verbose models are not truncated.
        var proposalOutputTokens: Int?
    }
    /// Package scope applies only while the whole production source fits the prompt budget.
    static let packageScopeLimitBytes = 40 * 1024
    package enum Failure: Error { case scope, alreadyStarted, context, testDiff, environmentInvalid }
    /// The pipeline body for one task. `root` must lie inside `candidate/work/` (isolation requirement);
    /// `output` receives the run record and evidence. Behaviour is identical for the CLI and for tests.
    /// Every model call of the run is appended to `output/model-calls.jsonl` (ModelCallLog, backlog #41).
    package static func runTask(candidate: URL, root: URL, key: String, model: String, output: URL) async throws {
        try await ModelCallLog.$destination.withValue(output.appendingPathComponent("model-calls.jsonl")) {
            try await runTaskLogged(candidate: candidate, root: root, key: key, model: model, output: output)
        }
    }

    /// Marks the run failed at `stage` with the rollback outcome and the recovery budget spent, and saves the record.
    static func recordFailure(_ stage: String, _ error: Error, rollback: String, record: BatchRunRecord,
                              budget: RequirementCoverage.Budget) throws {
        record["phase"] = "failed:\(stage)"; record["error"] = String(describing: error)
        record["failureClass"] = record["failureClass"] ?? stage
        record["modelResult"] = "UNVERIFIED"; record["harnessResult"] = "HARNESS_FAIL"
        noteRollback(record, rollback); record["promotionEligible"] = false
        record["recoveryBudgetUsed"] = budget.used.map(\.rawValue)
        classifyEnvironment(record); try record.save()
    }

    /// Undoes the repair transaction (if one was started) and then the proposal's.
    static func rollback(_ tx: RecoverableFileBatch, _ repairTx: RecoverableFileBatch, _ repairState: URL, root: URL) async -> String {
        if FileManager.default.fileExists(atPath: repairState.path),
           (try? await repairTx.run(root: root, direction: .rollback)) == nil { return "REPAIR_ROLLBACK_FAILED" }
        return (try? await tx.run(root: root, direction: .rollback)) == nil ? "FAILED" : "PASS"
    }
}
