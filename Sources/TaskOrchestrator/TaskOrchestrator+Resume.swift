import Foundation
import HarnessCore
import HarnessExecution
import HarnessKernel

/// Resume after a killed run. Never calls the model and never re-applies an edit. The journal names the
/// stage that was in flight; the result record says whether the requirement gate had already opened.
/// - gate opened (pending request written): the run is closed as it stood — continue to `paused(pending)`.
/// - anything else: every prepared edit transaction is rolled back (newest first, content-checked by
///   RecoverableFileBatch), protected files are compared with the acceptance contract, and the run stops
///   fail-closed as `interrupted:<stage>` / HARNESS_FAIL.
extension TaskOrchestrator {
    package enum ResumeOutcome: Equatable, Sendable {
        case notStarted
        case alreadyStopped(String)
        case closedAtRequirementGate
        case stoppedFailClosed(stage: String, rollback: String)
    }

    package static func resume(root: URL, output: URL) async throws -> ResumeOutcome {
        let lease = try LocalExecutionLease(file: output.appendingPathComponent("runner.lock"))
        defer { withExtendedLifetime(lease) {} }
        let journal = output.appendingPathComponent("kernel")
        guard let state = try OrchestratorLedger.replay(directory: journal) else { return .notStarted }
        if state.phase == .paused { return .alreadyStopped(state.pauseReason ?? "") }
        let resultURL = output.appendingPathComponent("result.json")
        guard var values = try JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any],
              let objective = values["objective"] as? String, let model = values["model"] as? String else { throw Failure.scope }
        let ledger = try await OrchestratorLedger(directory: journal, objective: objective, model: model)
        let pending = "testsPassedRequirementVerificationPending"
        if values["phase"] as? String == pending,
           FileManager.default.fileExists(atPath: output.appendingPathComponent(BatchRequirementGate.requestName).path) {
            try await ledger.stop(phase: pending, succeeded: true)
            return .closedAtRequirementGate
        }
        let stage = OrchestratorLedger.stage(of: state.activeAttempt, in: state)
            ?? "after:" + (state.plan?.steps.last { state.completedStepIDs.contains($0.id) }?.instruction ?? "start")
        let rollback = await rollBackAll(root: root, output: output)
        var protectedIntact = true
        if let contract = try? JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("acceptance-contract.json")))
            as? [String: Any], let expected = contract["protectedFiles"] as? [String: String], !expected.isEmpty {
            let current = try? await RepairAcceptanceContract.capture(root: root, paths: Array(expected.keys))
            protectedIntact = current?.protectedFiles == expected
        }
        let current = (values["rollbackResult"] as? String).flatMap(RollbackOutcome.init(rawValue:))
        values["rollbackResult"] = RollbackOutcome.merge(current, RollbackOutcome(detail: rollback)).rawValue
        values["rollbackEvents"] = ((values["rollbackEvents"] as? [Any]) ?? []) + ["resume: \(rollback)"]
        values["recoveryActions"] = ((values["recoveryActions"] as? [Any]) ?? []) + ["resumeAfterInterrupt"]
        values["phase"] = "interrupted:\(stage)"
        values["failureClass"] = "INTERRUPTED (resumed fail-closed; no model call, no reapply)"
        values["protectedFilesIntact"] = protectedIntact
        values["modelResult"] = "UNVERIFIED"; values["harnessResult"] = "HARNESS_FAIL"; values["promotionEligible"] = false
        try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: resultURL, options: .atomic)
        try await ledger.stop(phase: "interrupted:\(stage)")
        return .stoppedFailClosed(stage: stage, rollback: rollback)
    }

    /// "NOT_NEEDED" when nothing was prepared, "PASS" when every prepared transaction ends unapplied.
    static func rollBackAll(root: URL, output: URL) async -> String {
        var any = false
        for attempt in (1...2).reversed() {
            for name in ["transaction-repair", "transaction"] {
                let dir = output.appendingPathComponent("attempt-\(attempt)/\(name)")
                guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("transaction.json").path) else { continue }
                any = true
                guard (try? await RecoverableFileBatch(directory: dir).run(root: root, direction: .rollback)) != nil else { return "FAILED" }
            }
        }
        return any ? "PASS" : "NOT_NEEDED"
    }
}
