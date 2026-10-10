import Foundation
import HarnessCore
import HarnessExecution

/// One Target Replan per task: only for requirements that need a change, have no Editable
/// Owner and have directly related read-only evidence. The model nominates; the Harness
/// promotes only nominations with deterministic evidence, never all read-only evidence.
enum BatchTargetReplanStage {
    static func replan(directory: URL, plan: RequirementCoveragePlan, entries: [TargetCoverage.Entry],
                       objective: String, model: String, scope: inout BatchScope, sources: [String: String],
                       tests: [String: String], protected: Set<String>, budget: inout RequirementCoverage.Budget,
                       record: BatchRunRecord) async throws -> RequirementCoveragePlan {
        let gaps = TargetCoverage.blockingGaps(entries)
        var log: [String: Any] = ["attemptDirectory": directory.lastPathComponent,
                                  "gaps": gaps.map(\.requirementID), "editableBefore": scope.editable]
        func stop(_ reason: String) throws -> Never {
            log["result"] = "TARGET_COVERAGE_FAIL"; log["reason"] = reason
            record.append("targetReplans", log); record["failureClass"] = "TARGET_COVERAGE_FAIL"
            try record.save()
            throw BatchCoverageStage.Stop.targetCoverageFail(reason)
        }
        guard budget.consume(.targetReplan) else { try stop("targetReplanBudgetUnavailable") }
        record.append("recoveryActions", "targetReplan(TARGET_COVERAGE_GAP)")
        record.increment("targetReplanCount"); record.increment("modelPlanCalls"); try record.save()
        let evidenceFiles = Set(gaps.flatMap(\.readOnlyEvidence))
        let prompt = try TargetCoverage.nominationPrompt(objective: objective, gaps: gaps,
            editable: sources.filter { scope.editable.contains($0.key) },
            evidence: sources.filter { evidenceFiles.contains($0.key) }.mapValues {
                EvidenceSnippet.select(source: $0, relevant: gaps.flatMap { $0.existingSymbols + $0.newSymbols }) })
        let response = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
            messages: [.init(role: .user, content: prompt)], maximumOutputTokens: 768, structuredOutput: .targetNomination))
        try JSONSerialization.data(withJSONObject: ["response": response], options: [.prettyPrinted])
            .write(to: directory.appendingPathComponent("target-replan.json"), options: .atomic)
        guard let answer = try? JSONDecoder().decode(TargetNomination.self, from: Data(response.utf8)) else {
            try stop("nominationUnparseable")
        }
        log["nominations"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(answer))) ?? []
        guard !answer.nominations.isEmpty else { try stop("noNomination") }
        let verdicts = answer.nominations.prefix(TargetNomination.maximumItems).map {
            TargetCoverage.verify($0, gaps: gaps, objective: objective, editable: Set(scope.editable),
                                  sources: sources, tests: tests, protected: protected)
        }
        log["verdicts"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(verdicts)))) ?? []
        var promoted: [String] = []
        for verdict in verdicts where verdict.accepted && !promoted.contains(verdict.file) {
            guard promoted.count < TargetCoverage.promotionLimit(gaps: gaps) else { break }
            promoted.append(verdict.file)
        }
        scope.apply(.init(added: promoted, promoted: promoted))
        log["promoted"] = promoted; log["editableAfter"] = scope.editable
        record["permittedFiles"] = scope.editable; record["readOnlyEvidence"] = scope.readOnly
        let after = TargetCoverage.assess(plan, objective: objective, editable: Set(scope.editable),
                                          readOnly: Set(scope.readOnly), sources: sources)
        log["coverageAfter"] = BatchTargetReplanStage.encode(after)
        let remaining = TargetCoverage.blockingGaps(after).map(\.requirementID)
        guard remaining.isEmpty else {
            try stop(promoted.isEmpty ? "noNominationVerified" : "gapRemains(\(remaining.joined(separator: ",")))")
        }
        log["result"] = "RESOLVED"; record.append("targetReplans", log); try record.save()
        return TargetCoverage.patch(plan, before: entries, after: after)
    }

    static func encode(_ entries: [TargetCoverage.Entry]) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(entries))) ?? []
    }
}
