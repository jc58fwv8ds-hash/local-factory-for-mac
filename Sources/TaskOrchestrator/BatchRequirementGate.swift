import Foundation
import HarnessCore
import HarnessExecution

/// Post-Implementation Requirement Gate for batch runs. `open` replaces the tests-passed
/// finalization with a pending state plus a verification request (objective clauses, accepted
/// requirements, production diff/code; no tests). The CLI `--requirement-verify` command ingests an
/// independent verifier's report and records the decision beside — never over — the raw tests-passed result.
package enum BatchRequirementGate {
    package static let requestName = "requirement-verification-request.json"

    static func open(record: BatchRunRecord, output: URL, key: String, objective: String, clauses: [ObjectiveClause],
                     plan: RequirementCoveragePlan, proposals: [FileChangeProposal], protected: Set<String>,
                     builderModel: String, testsPassedResult: String) throws {
        // Immutable tests-passed observation; result.json is only the current state projection.
        try JSONSerialization.data(withJSONObject: record.values, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("raw-result.json"), options: .withoutOverwriting)
        let request = RequirementVerification.request(taskID: key, objective: objective, clauses: clauses, plan: plan,
            proposals: proposals, protected: protected, builderModel: builderModel)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(request).write(to: output.appendingPathComponent(requestName), options: .atomic)
        record["testsPassedHarnessResult"] = testsPassedResult
        record["LOCAL_AUTONOMOUS_VERIFIER"] = false
        record["verificationMode"] = "external_manual_independent_review"
        record["harnessResult"] = RequirementVerification.pendingResult
        record["phase"] = "testsPassedRequirementVerificationPending"
        record["requirementVerification"] = ["status": "PENDING", "request": requestName,
                                             "requiredItems": request.requiredIDs] as [String: Any]
        try record.save()
    }
}
