import Foundation
import HarnessCore
import HarnessExecution
import TaskOrchestrator

/// Finalizes a pending batch run from an independent verifier's report (BatchRequirementGate).
enum BatchRequirementFinalizeCommand {
    typealias Failure = TaskOrchestrator.Failure
    /// `--requirement-verify <candidate> <key> <report.json>`. Rolls back the task's applied change
    /// when the requirements are violated or uncertain, so a failed task leaves no edit behind.
    static func finalize(arguments: [String]) async throws {
        guard arguments.count == 5 else { throw Failure.scope }
        let candidate = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        let key = arguments[3]
        guard candidate.lastPathComponent == "dogfood-candidate",
              key.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else { throw Failure.scope }
        let output = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessCandidate/Dogfood/\(key)")
        let resultURL = output.appendingPathComponent("result.json")
        let lease = try LocalExecutionLease(file: output.appendingPathComponent("runner.lock"))
        defer { withExtendedLifetime(lease) {} }
        guard var values = try JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any],
              values["harnessResult"] as? String == RequirementVerification.pendingResult,
              let testsPassed = values["testsPassedHarnessResult"] as? String else {
            print("Requirement gate: \(key) is not pending verification; nothing changed."); throw Failure.scope
        }
        let request = try JSONDecoder().decode(RequirementVerification.Request.self,
                                               from: Data(contentsOf: output.appendingPathComponent(BatchRequirementGate.requestName)))
        let reportData = try Data(contentsOf: URL(fileURLWithPath: arguments[4]))
        let report = try JSONDecoder().decode(RequirementVerification.Report.self, from: reportData)
        let decision = RequirementVerification.decide(report, for: request)
        let adjudicationID = UUID().uuidString
        try reportData.write(to: output.appendingPathComponent("verifier-report-\(adjudicationID).json"), options: .withoutOverwriting)
        let final = RequirementVerification.finalResult(testsPassedResult: testsPassed, decision: decision)
        var gate: [String: Any] = ["status": decision.outcome.rawValue, "reasons": decision.reasons,
            "qualityWarnings": decision.qualityWarnings, "verifier": ["role": report.verifier.role, "identity": report.verifier.identity],
            "items": report.items.map { ["id": $0.id, "verdict": $0.verdict.rawValue, "evidence": $0.evidence] }]
        if decision.outcome == .REQUIREMENT_VIOLATION || decision.outcome == .REQUIREMENT_UNCERTAIN {
            let root = candidate.appendingPathComponent("work/canary-\(key)")
            var events: [String] = []
            for attempt in (1...2).reversed() {
                for name in ["transaction-repair", "transaction"] {
                    let dir = output.appendingPathComponent("attempt-\(attempt)/\(name)")
                    guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("transaction.json").path) else { continue }
                    let rolled = (try? await RecoverableFileBatch(directory: dir).run(root: root, direction: .rollback)) != nil
                    events.append("attempt-\(attempt)/\(name): \(rolled ? "PASS" : "FAILED")")
                }
            }
            gate["rollbackEvents"] = events
            values["rollbackResult"] = events.isEmpty ? values["rollbackResult"] ?? "NOT_ATTEMPTED"
                : (events.allSatisfy { $0.hasSuffix("PASS") } ? "ATTEMPTED_SUCCESS" : "ATTEMPTED_FAIL")
        }
        values["requirementVerification"] = gate
        values["harnessResult"] = final
        values["phase"] = decision.outcome == .REQUIREMENTS_SATISFIED ? "requirementVerified" : "requirementGate:\(decision.outcome.rawValue)"
        let adjudicated = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try adjudicated.write(to: output.appendingPathComponent("adjudicated-result-\(adjudicationID).json"), options: .withoutOverwriting)
        try adjudicated.write(to: resultURL, options: .atomic)
        print("Requirement gate \(key): \(decision.outcome.rawValue) → \(final)")
    }
}
