import Foundation
import HarnessCore
import HarnessExecution

/// Requirement Coverage Plan stage: the edit stage is entered only when every
/// requirement has an editable target or an explicit no-change reason.
enum BatchCoverageStage {
    enum Stop: Error { case planUnavailable, coverageIncomplete(String), promotionRejected, objectiveClauseUncovered([String]), targetCoverageFail(String) }

    static func plan(directory: URL, feedback: String?, objective: String, model: String, scope: inout BatchScope,
                     sources: inout [String: String], root: URL? = nil, protected: Set<String>, budget: inout RequirementCoverage.Budget,
                     promotionUsed: inout Bool, record: BatchRunRecord,
                     clauses: [ObjectiveClause] = [], targetCandidates: [RepositorySymbolIndex.Match] = [],
                     tests: [String: String] = [:]) async throws -> RequirementCoveragePlan {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var note = feedback
        var previousReady: RequirementCoveragePlan?
        for index in 1...3 {
            let readOnlyForModel = Dictionary(uniqueKeysWithValues: sources.filter { scope.readOnly.contains($0.key) }.map { file, source in
                let symbol = targetCandidates.filter { $0.file == file }
                    .sorted { $0.score == $1.score ? $0.symbol < $1.symbol : $0.score > $1.score }
                    .first?.symbol
                let others = scope.editable + scope.readOnly.filter { $0 != file }
                let relevant = EvidenceSnippet.identifiers(objective).sorted() + targetCandidates.map(\.symbol)
                    + others.flatMap { EvidenceSnippet.typeDeclarations(sources[$0] ?? "") }
                return (file, EvidenceSnippet.select(source: source, relevant: relevant,
                    contextReferences: Set(others.flatMap { EvidenceSnippet.identifiers(sources[$0] ?? "") }), matched: symbol))
            })
            let prompt = try RequirementCoverage.planPrompt(objective: objective,
                editable: sources.filter { scope.editable.contains($0.key) },
                readOnly: readOnlyForModel, feedback: note, clauses: clauses)
            record.increment("modelPlanCalls"); try record.save()
            let response = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                messages: SharedContextMessages.messages(for: prompt), maximumOutputTokens: 1536, structuredOutput: .coveragePlan))
            try JSONSerialization.data(withJSONObject: ["response": response, "feedback": note ?? ""], options: [.prettyPrinted])
                .write(to: directory.appendingPathComponent("plan-\(index).json"), options: .atomic)
            guard var plan = try? JSONDecoder().decode(RequirementCoveragePlan.self, from: Data(response.utf8)) else {
                throw Stop.planUnavailable
            }
            var assessment = RequirementCoverage.assess(plan, editable: Set(scope.editable),
                readOnly: Set(scope.readOnly), sources: sources)
            // A plan may put a new type in a new file of an existing target (bounded, see creatableFiles). The Harness
            // writes a placeholder so the unchanged edit/transaction path applies and rolls back to it.
            if let root, !assessment.invalidTargets.isEmpty {
                let created = (record["createdFiles"] as? [String]) ?? []
                for file in RequirementCoverage.creatableFiles(assessment.invalidTargets, sources: sources,
                                                               protected: protected, alreadyCreated: created.count) {
                    let url = root.appendingPathComponent(file)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        try RequirementCoverage.newFilePlaceholder.write(to: url, atomically: true, encoding: .utf8)
                    }
                    sources[file] = RequirementCoverage.newFilePlaceholder
                    scope.editable = Array(Set(scope.editable + [file])).sorted()
                    record.append("createdFiles", file)
                }
                try record.save()
                assessment = RequirementCoverage.assess(plan, editable: Set(scope.editable),
                    readOnly: Set(scope.readOnly), sources: sources)
            }
            var promotions: [[String: Any]] = []
            if assessment.status == .planRequestsEscalation && !promotionUsed {
                promotionUsed = true
                for file in assessment.requestedFiles {
                    // READ-ONLY evidence (including reverse references) is never promoted here: the edit
                    // request becomes a Target Coverage gap and only Target Replan validation can promote it.
                    if scope.nominationOnly.contains(file) || scope.readOnly.contains(file) {
                        promotions.append(["file": file, "accepted": false, "promoted": [String](),
                                           "routedTo": "TargetReplan", "rejection": "readOnlyEditRequestRouted"])
                        continue
                    }
                    let why = plan.requirements.filter { $0.editable_targets.contains(file) }.map(\.rationale).joined(separator: " / ")
                    let discoveryEvidence = TargetDiscoveryPolicy.promotionEvidence(file: file, plan: plan,
                        candidates: targetCandidates, sources: sources)
                    let decision = ContextEscalation.evaluate(.init(file: file, symbol: nil, why_needed: why.isEmpty ? "listed as editable target" : why,
                        relation: "listed as editable target in coverage plan", operation: "edit"), objective: objective,
                        targets: scope.editable, contextSet: scope.editable + scope.readOnly, sources: sources, protected: protected)
                    let accepted = decision.accepted || discoveryEvidence != nil
                    let promoted = accepted ? [file] : []
                    promotions.append(["file": file, "accepted": accepted, "promoted": promoted,
                                       "evidence": discoveryEvidence ?? decision.evidence[file] ?? [],
                                       "rejection": accepted ? "" : decision.rejection ?? ""])
                    if accepted { scope.apply(.init(added: [file], promoted: promoted)) }
                }
                assessment = RequirementCoverage.assess(plan, editable: Set(scope.editable),
                    readOnly: Set(scope.readOnly), sources: sources)
            }
            // Target Coverage: every requirement that needs a change must have an Editable Owner
            // before any proposal; a blocking gap gets one Target Replan or ends the task.
            let targetCoverage = TargetCoverage.assess(plan, objective: objective, editable: Set(scope.editable),
                readOnly: Set(scope.readOnly), sources: sources)
            record.append("targetCoverage", ["attemptDirectory": directory.lastPathComponent, "index": index,
                "entries": BatchTargetReplanStage.encode(targetCoverage)] as [String: Any])
            if !TargetCoverage.blockingGaps(targetCoverage).isEmpty {
                plan = try await BatchTargetReplanStage.replan(directory: directory, plan: plan, entries: targetCoverage,
                    objective: objective, model: model, scope: &scope, sources: sources, tests: tests,
                    protected: protected, budget: &budget, record: record)
                assessment = RequirementCoverage.assess(plan, editable: Set(scope.editable),
                    readOnly: Set(scope.readOnly), sources: sources)
            }
            record.append("coveragePlans", ["attemptDirectory": directory.lastPathComponent, "index": index,
                "plan": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))) ?? [:],
                "status": assessment.status.rawValue, "uncovered": assessment.uncovered,
                "relatedEvidence": assessment.relatedEvidence, "invalidTargets": assessment.invalidTargets,
                "planRequestedPromotions": promotions, "editable": scope.editable, "readOnly": scope.readOnly] as [String: Any])
            record["permittedFiles"] = scope.editable; record["readOnlyEvidence"] = scope.readOnly; try record.save()
            switch assessment.status {
            case .ready:
                // Clause Coverage Gate: deterministic objective clauses, not the model's self-report.
                var coverage = RequirementCoverage.clauseCoverage(plan, clauses: clauses, sources: sources)
                if !coverage.complete, let previous = previousReady {
                    let merged = RequirementCoverage.carryingOver(plan, previous: previous, uncovered: coverage.uncovered)
                    let mergedCoverage = RequirementCoverage.clauseCoverage(merged, clauses: clauses, sources: sources)
                    let mergedStatus = RequirementCoverage.assess(merged, editable: Set(scope.editable),
                        readOnly: Set(scope.readOnly), sources: sources).status
                    if mergedStatus == .ready && mergedCoverage.uncovered.count < coverage.uncovered.count {
                        record.append("clauseCarryOver", ["index": index, "carried": merged.requirements.count - plan.requirements.count,
                            "uncoveredBefore": coverage.uncovered, "uncoveredAfter": mergedCoverage.uncovered] as [String: Any])
                        plan = merged; coverage = mergedCoverage
                    }
                }
                previousReady = plan
                record.append("clauseCoverageChecks", ["attemptDirectory": directory.lastPathComponent, "index": index,
                    "covered": coverage.covered, "uncovered": coverage.uncovered,
                    "unknownCitations": coverage.unknownCitations, "requirementCount": plan.requirements.count] as [String: Any])
                record["objectiveClauseCount"] = coverage.objectiveClauseCount
                record["mandatoryClauseCount"] = coverage.mandatory.count
                record["coveredClauseCount"] = coverage.covered.count
                record["uncoveredClauseIDs"] = coverage.uncovered
                record["requirementCount"] = plan.requirements.count
                record["finalClauseCoverage"] = "\(coverage.covered.count)/\(coverage.mandatory.count)"
                try record.save()
                if coverage.complete { return plan }
                guard budget.consume(.clauseReplan) else {
                    record["extractionFailure"] = true
                    throw Stop.objectiveClauseUncovered(coverage.uncovered)
                }
                record.append("recoveryActions", "clauseReplan(OBJECTIVE_CLAUSE_UNCOVERED)")
                record.increment("clauseReplanCount")
                note = RequirementCoverage.clauseReplanFeedback(coverage, clauses: clauses)
            case .planRequestsEscalation: throw Stop.promotionRejected
            case .incomplete:
                // One bounded replan when there is something editable to target; with an empty
                // EditableTargets set a replan cannot help (context failure) and is not attempted.
                guard !scope.editable.isEmpty, budget.consume(.clauseReplan) else {
                    throw Stop.coverageIncomplete("no editable target or no-change reason, no related evidence")
                }
                record.append("recoveryActions", "clauseReplan(requirementWithoutTargetOrReason)")
                record.increment("clauseReplanCount")
                note = RequirementCoverage.incompleteFeedback(assessment)
            case .needsContextReplan:
                // Harness-driven under-escalation replan, once per task (shared with context_request).
                guard budget.consume(.contextReplan) else {
                    throw Stop.coverageIncomplete("under-escalation unresolved")
                }
                record.append("recoveryActions", "contextReplan(harnessDetectedUnderEscalation)")
                record["underEscalationDetected"] = true
                note = RequirementCoverage.contextReplanFeedback(assessment)
            }
        }
        throw Stop.coverageIncomplete("replan budget exhausted")
    }
}
