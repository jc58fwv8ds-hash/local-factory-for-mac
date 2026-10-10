import Foundation
import HarnessCore
import HarnessExecution
import HarnessKernel

/// One request through plan -> edit -> isolated build/test -> repair -> requirement gate.
/// Source context comes from ContextSelector. Without `allowedFiles` (D2), write permission
/// is exactly the selected non-test, non-protected files: no task-specific allowlist.
package enum TaskOrchestrator {
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
    package static func runTask(candidate: URL, root: URL, key: String, model: String, output: URL) async throws {
        guard root.path.hasPrefix(candidate.path + "/work/") else { throw Failure.scope }
        let task = try JSONDecoder().decode(Task.self, from: Data(contentsOf: root.appendingPathComponent("task.json")))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let lease = try LocalExecutionLease(file: output.appendingPathComponent("runner.lock"))
        defer { withExtendedLifetime(lease) {} }
        let result = output.appendingPathComponent("result.json")
        guard !FileManager.default.fileExists(atPath: result.path) else {
            let recovery = await BatchRecoveryInspector().inspect(root: root,
                checkpoint: output.appendingPathComponent("proposal/checkpoint.json"))
            print("Existing batch: \(recovery.rawValue). No reapply, rollback or model retry performed.")
            throw Failure.alreadyStarted
        }
        // Inference Health Gate: nothing runs unless a small probe is healthy relative to the
        // known healthy baseline; an unhealthy start is ENVIRONMENT_INVALID, not a task result.
        let (preHealth, preVerdict) = try await InferenceHealthGate.check(model: model, context: "\(key):preTask")
        guard preVerdict.healthy else {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            try JSONSerialization.data(withJSONObject: ["key": key, "classification": "ENVIRONMENT_INVALID",
                "phase": "preTaskHealthGate", "reasons": preVerdict.reasons, "measurement": Self.json(preHealth),
                "reference": Self.json(preVerdict.reference)], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("environment-invalid-\(stamp).json"), options: .atomic)
            print("Canary \(key): ENVIRONMENT_INVALID before start (\(preVerdict.reasons.joined(separator: ", "))). No task step ran.")
            throw Failure.environmentInvalid
        }
        InferenceEnvironment.shared.begin(reference: preVerdict.reference)
        try Data("started".utf8).write(to: output.appendingPathComponent("task-started"), options: .atomic)
        let start = Date()
        let editor = RecordedProjectFileEditor(directory: output.appendingPathComponent("edits"))
        let all = try await ProjectFileEditor().editableFiles(rootPath: root.path)
        var evidence: [ContextFileEvidence] = []
        for file in all where file.relativePath.hasSuffix(".swift") && !task.protectedFiles.contains(file.relativePath) {
            let document = try await editor.load(rootPath: root.path, relativePath: file.relativePath)
            evidence.append(.init(path: file.relativePath, source: document.content))
        }
        // Test sources are relation evidence for Target Replan only (symbol names; never shown to the model).
        var tests: [String: String] = [:]
        for file in all where file.relativePath.hasSuffix(".swift") && file.relativePath.contains("Tests/") && !task.protectedFiles.contains(file.relativePath) {
            tests[file.relativePath] = try await editor.load(rootPath: root.path, relativePath: file.relativePath).content
        }
        let clauses = ObjectiveClauses.segment(task.objective)
        var sources = Dictionary(evidence.map { ($0.path, $0.source) }, uniquingKeysWith: { first, _ in first })
        let sourcesAtStart = sources
        let selection = ContextSelector.select(objective: task.objective, paths: evidence.map(\.path), evidence: evidence)
        let selected = Array(Set(selection.files + selection.tests + task.appendOnly)).sorted()
        let record = BatchRunRecord(url: result, start: start, values: ["phase": "contextSelected", "objective": task.objective,
            "selectedFiles": selected, "selectedTests": selection.tests, "selectionReasons": selection.reasons,
            "contextSeconds": Date().timeIntervalSince(start), "model": model, "modelProposalCount": 0,
            "modelPlanCalls": 0, "modelResult": "UNVERIFIED", "harnessResult": "UNVERIFIED", "fallbackUsed": false,
            "humanInterventionsDuringRun": 0, "recoveryActions": [String](), "underEscalationDetected": false,
            "modelFirstPass": "UNVERIFIED", "rollbackResult": RollbackOutcome.NOT_ATTEMPTED.rawValue, "modelCompilerRepair": "NOT_RUN", "modelRequirementReplan": "NOT_RUN",
            "escalation": "NOT_REQUESTED", "targetDiscoveryCount": 0, "modelTargetDiscoveryCalls": 0,
            "initialCandidates": BatchTargetDiscoveryStage.encode(selection.initialCandidates),
            "recoveryBudget": ["perKind": 1, "task": RequirementCoverage.Budget.taskLimit],
            "preTaskHealth": ["measurement": Self.json(preHealth), "verdict": Self.json(preVerdict)],
            "capabilityValid": true])
        try record.save()
        // Parent Kernel Run: each stage below is a durable step (resume: TaskOrchestrator+Resume).
        let ledger = try await OrchestratorLedger(directory: output.appendingPathComponent("kernel"), objective: task.objective, model: model)
        try await ledger.begin("context")
        // Readable context != editable scope: EditableTargets are the selector's targets;
        // evidence is read-only unless promoted through deterministic evidence.
        var scope = BatchScope(editable: task.allowedFiles ?? selection.targets.filter { !task.protectedFiles.contains($0) },
                               readOnly: [])
        scope.readOnly = selection.files.filter { !scope.editable.contains($0) && !task.protectedFiles.contains($0) }
        let uniqueSeedReferences = ReverseReferenceExpansion.discover(seeds: selection.initialCandidates,
            sources: sources, alreadySelected: Set(selection.files), protected: Set(task.protectedFiles))
        // Declaration seeds + retained strong candidates; same READ-ONLY bound, never editable.
        let reverseReferences = Array((uniqueSeedReferences + DeclarationSeedExpansion.expand(selected: selection.files,
            targets: Set(scope.editable), objective: task.objective, initialCandidates: selection.initialCandidates, sources: sources,
            protected: Set(task.protectedFiles), excluding: Set(uniqueSeedReferences.map(\.candidateFile)))).prefix(ReverseReferenceExpansion.maximumFiles))
        scope.readOnly = Array(Set(scope.readOnly + reverseReferences.map(\.candidateFile))).sorted()
        scope.nominationOnly = Set(reverseReferences.map(\.candidateFile))
        record["reverseReferenceExpansion"] = Self.json(reverseReferences)
        record["reverseReferenceAddedReadOnlyCount"] = reverseReferences.count
        record["protectedTestAssistedPromotion"] = 0
        var targetCandidates = selection.initialCandidates
        var targetDiscoveryBudget = TargetDiscoveryPolicy.Budget()
        // Production sources only: never test files, never the package manifest (it could drop or rewire test targets).
        let production = evidence.map(\.path).filter { $0.hasPrefix("Sources/") && !$0.split(separator: "/").contains("Tests") }.sorted()
        let packageScope = task.allowedFiles == nil && (task.scopeMode ?? "package") == "package"
            && production.reduce(0) { $0 + (sources[$1]?.utf8.count ?? 0) } <= Self.packageScopeLimitBytes
        if task.allowedFiles == nil && (task.scopeMode ?? "package") == "package" && !packageScope {
            record["scopeModeFallback"] = "packageTooLarge"
        }
        if packageScope { scope = BatchScope(nominationOnly: [], editable: production, readOnly: []) }
        if task.allowedFiles == nil && !packageScope && selection.needsTargetDiscovery {
            do {
                let discovered = try await BatchTargetDiscoveryStage.discover(objective: task.objective, clauses: clauses,
                    model: model, sources: sources, existing: targetCandidates,
                    budget: &targetDiscoveryBudget, record: record)
                targetCandidates = Array((targetCandidates + discovered).reduce(into: [String: RepositorySymbolIndex.Match]()) {
                    let key = $1.file + "\u{0}" + $1.symbol + "\u{0}" + $1.clauseID
                    if $0[key] == nil || $0[key]!.score < $1.score { $0[key] = $1 }
                }.values).sorted { $0.score == $1.score ? $0.file < $1.file : $0.score > $1.score }
                let additions = discovered.map(\.file).filter { !task.protectedFiles.contains($0) && !scope.editable.contains($0) }
                scope.readOnly = Array(Set(scope.readOnly + additions).sorted().prefix(5))
            } catch {
                record["phase"] = "failed:targetDiscovery"; record["failureClass"] = "CONTEXT_FAIL"
                record["error"] = String(describing: error); record["modelResult"] = "UNVERIFIED"
                record["harnessResult"] = "HARNESS_FAIL"; record["promotionEligible"] = false
                Self.classifyEnvironment(record); try record.save()
                try? await ledger.stop(phase: "failed:targetDiscovery"); throw error
            }
        }
        record["scopeSource"] = task.allowedFiles != nil ? "taskManifest" : (packageScope ? "package" : "contextSelector")
        record["selectedFiles"] = Array(Set(scope.editable + scope.readOnly + selection.tests + task.appendOnly)).sorted()
        record["contextFileCount"] = Set(scope.editable + scope.readOnly + selection.tests).count
        record["contextBytes"] = Set(scope.editable + scope.readOnly + selection.tests).reduce(0) { $0 + (sources[$1]?.utf8.count ?? 0) }
        let discoveryEntries = targetCandidates.filter { candidate in
            scope.readOnly.contains(candidate.file) && !selection.entries.contains(where: { $0.path == candidate.file })
        }.map { ContextSelector.Entry(path: $0.file, role: .evidence,
            reasons: ["\($0.evidenceType): \($0.reason)", "matched clause \($0.clauseID)"],
            relation: $0.evidenceType, score: $0.score) }
        record["contextEntries"] = BatchProposalStage.encode(selection.entries + discoveryEntries, editable: Set(scope.editable))
        record["targetCandidates"] = BatchTargetDiscoveryStage.encode(targetCandidates)
        record["permittedFiles"] = scope.editable; record["readOnlyEvidence"] = scope.readOnly; try record.save()
        let contract = try await RepairAcceptanceContract.capture(root: root, paths: task.protectedFiles)
        try JSONEncoder().encode(contract).write(to: output.appendingPathComponent("acceptance-contract.json"), options: .atomic)
        let protected = Set(task.protectedFiles)
        // This path never invokes the unrestricted trusted-project validator.
        let isolated = IsolatedPackageExecution(candidate: candidate, root: root, taskID: key,
            protectedPaths: task.protectedFiles, stable: candidate.deletingLastPathComponent().deletingLastPathComponent())
        let isolation = output.appendingPathComponent("isolation")
        let route = KernelRoutingPolicy.decide(work: .deterministic, localCompatible: false,
            subscriptionDispatchVerified: false, solAvailable: false, astraAvailable: false)
        guard route.route == .tools else { throw Failure.scope }
        // Objective Clause Segmentation: preserve every information unit of the objective.
        record["objectiveClauses"] = clauses.map { ["id": $0.clauseID, "text": $0.exactSourceText, "range": $0.sourceRange,
            "type": $0.clauseType.rawValue, "features": $0.features, "mandatory": $0.mandatoryCandidate] as [String: Any] }
        record["objectiveClauseCount"] = clauses.count
        record["mandatoryClauseCount"] = clauses.filter(\.mandatoryCandidate).count
        record["clauseReplanCount"] = 0; record["extractionFailure"] = false
        try await ledger.end("context")
        var budget = RequirementCoverage.Budget()
        var promotionUsed = false
        var feedback: String?
        var previousDiff: String?
        var runtimeFeedback: String?
        var runtimePlan: RequirementCoveragePlan?

        func label(_ attempt: Int, repaired: Bool, pass: Bool) {
            let verdict = pass ? "PASS" : "FAIL"
            // A proposal that needed an anchor repair is not a first-pass result.
            if attempt == 1 && !repaired {
                record["modelFirstPass"] = budget.used.contains(.anchorRepair) ? "MODEL_FIRST_PASS_FAIL" : "MODEL_FIRST_PASS_\(verdict)"
            }
            if repaired { record["modelCompilerRepair"] = "MODEL_COMPILER_REPAIR_\(verdict)" }
            if attempt == 2 {
                if runtimeFeedback != nil { record["modelRuntimeRepair"] = "MODEL_RUNTIME_REPAIR_\(verdict)" }
                else { record["modelRequirementReplan"] = "MODEL_REQUIREMENT_REPLAN_\(verdict)" }
            }
        }
        func fail(_ stage: String, _ error: Error, rollback: String = "NOT_NEEDED") throws {
            record["phase"] = "failed:\(stage)"; record["error"] = String(describing: error)
            record["failureClass"] = record["failureClass"] ?? stage
            record["modelResult"] = "UNVERIFIED"; record["harnessResult"] = "HARNESS_FAIL"
            Self.noteRollback(record, rollback); record["promotionEligible"] = false
            record["recoveryBudgetUsed"] = budget.used.map(\.rawValue)
            Self.classifyEnvironment(record); try record.save()
        }
        func rollback(_ tx: RecoverableFileBatch, _ repairTx: RecoverableFileBatch, _ repairState: URL) async -> String {
            if FileManager.default.fileExists(atPath: repairState.path),
               (try? await repairTx.run(root: root, direction: .rollback)) == nil { return "REPAIR_ROLLBACK_FAILED" }
            return (try? await tx.run(root: root, direction: .rollback)) == nil ? "FAILED" : "PASS"
        }

        attempts: for attempt in 1...2 {
            let dir = output.appendingPathComponent("attempt-\(attempt)")
            record["attempt"] = attempt; record["phase"] = "planning"; try record.save()
            try await ledger.begin("plan")
            let plan: RequirementCoveragePlan
            do {
                if let runtimePlan { plan = runtimePlan } else {
                plan = try await BatchCoverageStage.plan(directory: dir, feedback: feedback, objective: task.objective,
                    model: model, scope: &scope, sources: &sources, root: root, protected: protected, budget: &budget,
                    promotionUsed: &promotionUsed, record: record, clauses: clauses, targetCandidates: targetCandidates, tests: tests)
                }
            } catch {
                if case BatchCoverageStage.Stop.objectiveClauseUncovered = error {
                    record["failureClass"] = "REQUIREMENT_EXTRACTION_FAIL (OBJECTIVE_CLAUSE_UNCOVERED)"
                } else if case BatchCoverageStage.Stop.targetCoverageFail = error {
                    record["failureClass"] = "TARGET_COVERAGE_FAIL"
                } else { record["failureClass"] = "Coverage plan (\(error))" }
                label(attempt, repaired: false, pass: false)
                try fail("plan", error); break attempts
            }
            try await ledger.end("plan")
            record["phase"] = "proposing"; try record.save()
            try await ledger.begin("propose")
            let proposals: [FileChangeProposal]
            do {
                proposals = try await BatchProposalStage.propose(directory: dir, plan: plan, objective: task.objective,
                    model: model, scope: &scope, sources: sources, protected: protected, appendOnly: task.appendOnly,
                    maxEdits: task.maxEdits, maxLines: task.maxLines, root: root, editor: editor, budget: &budget, record: record,
                    runtimeFeedback: runtimeFeedback, outputTokens: min(max(task.proposalOutputTokens ?? 2048, 512), 8192))
                guard Set(task.appendOnly).isSubset(of: Set(proposals.map(\.relativePath))) else { throw Failure.testDiff }
            } catch {
                record["failureClass"] = "ACI / Context (proposal rejected)"; label(attempt, repaired: false, pass: false)
                try fail("proposal", error); break attempts
            }
            // A replan that reproduces the rejected change is a repeated failure: stop before
            // spending build/test time on it.
            if let previousDiff, RuntimeRepair.fingerprint(proposals) == previousDiff {
                record["failureClass"] = "Repeated failure (replan reproduced the previous proposal)"
                label(attempt, repaired: false, pass: false)
                try fail("replanRepeated", Failure.scope); break attempts
            }
            try await ledger.end("propose")
            var attemptRecord: [String: Any] = ["attempt": attempt,
                "proposal": BatchProposalStage.savedResponse(in: dir.appendingPathComponent("proposal-escalated"))
                    ?? BatchProposalStage.savedResponse(in: dir.appendingPathComponent("proposal")) ?? "",
                "editOrder": proposals.map(\.relativePath), "editable": scope.editable, "readOnly": scope.readOnly,
                "scopeViolations": proposals.map(\.relativePath).filter { !scope.editable.contains($0) },
                "changedLines": proposals.map { ["file": $0.relativePath, "added": $0.summary.addedLineCount,
                                                 "removed": $0.summary.removedLineCount] as [String: Any] }]
            let tx = RecoverableFileBatch(directory: dir.appendingPathComponent("transaction"))
            let repairTx = RecoverableFileBatch(directory: dir.appendingPathComponent("transaction-repair"))
            let repairState = dir.appendingPathComponent("transaction-repair/transaction.json")
            try await ledger.begin("apply")
            try await tx.prepare(root: root, proposals: proposals, allowed: Set(scope.editable), protected: protected)
            record["phase"] = "applying"; try record.save()
            do {
                let applied = try await tx.run(root: root, direction: .resume)
                attemptRecord["partialApply"] = !applied.files.allSatisfy { $0.status == "applied" }
                try await ledger.end("apply")
            } catch {
                // A later file failing after an earlier one applied is never success.
                let observed = try? await tx.inspect(root: root)
                let before = observed?.files.filter { $0.status == "applied" }.map(\.path) ?? []
                attemptRecord["appliedBeforeFailure"] = before
                attemptRecord["partialApply"] = !before.isEmpty && before.count < (observed?.files.count ?? 0)
                record.append("attempts", attemptRecord); label(attempt, repaired: false, pass: false)
                let reverted = try? await tx.run(root: root, direction: .rollback)
                try fail("apply", error, rollback: reverted.map { $0.files.allSatisfy { $0.status == "unapplied" } ? "PASS" : "INCOMPLETE" } ?? "FAILED")
                break attempts
            }
            var repaired = false
            var changed = proposals
            do {
                try await ledger.begin("build")
                if let failure = try await BatchCompilerRepair.compile(isolated, evidence: isolation, root: root) {
                    // A first proposal that does not compile is a first-pass failure even if repair succeeds.
                    if attempt == 1 { record["modelFirstPass"] = "MODEL_FIRST_PASS_FAIL" }
                    attemptRecord["firstCompile"] = "FAIL"; attemptRecord["firstDiagnostics"] = BatchCompilerRepair.encode(failure.diagnostics)
                    attemptRecord["firstFailureClass"] = failure.failureClass.rawValue
                    let eligibility = CompilerRepair.eligibility(failure.diagnostics, permitted: Set(scope.editable),
                        protected: protected, readOnly: Set(scope.readOnly))
                    attemptRecord["repairEligibility"] = eligibility.rawValue
                    if eligibility == .readOnlyEvidenceDiagnostic {
                        record["failureClass"] = "Context / target selection / task design (read-only evidence must change)"
                    }
                    guard eligibility == .repairable else { throw BatchCompilerRepair.Stop.notRepairable(eligibility.rawValue) }
                    guard budget.consume(attempt == 1 ? .compilerRepair : .replanCompilerRepair) else { throw BatchCompilerRepair.Stop.notRepairable("recoveryBudgetExhausted") }
                    record.append("recoveryActions", "compilerRepair(attempt \(attempt))"); repaired = true; try record.save()
                    let repair = try await BatchCompilerRepair.attempt(root: root, output: dir, model: model,
                        objective: task.objective, firstPass: proposals, failure: failure, permitted: scope.editable,
                        protected: protected, maxEdits: task.maxEdits, maxLines: task.maxLines, editor: editor, transaction: repairTx,
                        budget: &budget, record: record)
                    record.increment("modelProposalCount")
                    changed += repair
                    attemptRecord["repairProposal"] = BatchProposalStage.savedResponse(in: dir.appendingPathComponent("repair-proposal")) ?? ""
                    if let again = try await BatchCompilerRepair.compile(isolated, evidence: isolation, root: root) {
                        attemptRecord["repairCompile"] = "FAIL"; attemptRecord["repairDiagnostics"] = BatchCompilerRepair.encode(again.diagnostics)
                        attemptRecord["sameFailureClassRecurred"] = again.failureClass == failure.failureClass
                        throw BatchCompilerRepair.Stop.repairDidNotCompile
                    }
                    attemptRecord["repairCompile"] = "PASS"
                } else { attemptRecord["firstCompile"] = "PASS" }
                attemptRecord["isolatedBuild"] = "PASS"; try record.save()
                try await ledger.end("build"); try await ledger.begin("test")
                switch try await BatchCompilerRepair.test(isolated, evidence: isolation) {
                case .passed:
                    changed += try await BatchLeftoverStage.followUp(root: root, directory: dir, model: model,
                        objective: task.objective, changed: changed, permitted: scope.editable, protected: protected,
                        maxEdits: task.maxEdits, maxLines: task.maxLines, editor: editor, isolated: isolated,
                        evidence: isolation, budget: &budget, record: record)
                    var visibleTests: [String: String] = [:]
                    for path in task.protectedFiles where path.hasSuffix(".swift") && path.split(separator: "/").contains("Tests") {
                        visibleTests[path] = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                    }
                    let risky = !(task.gatedChecks ?? false) || !RiskSignals.reasons(repaired: attempt > 1 || !budget.used.isEmpty,
                        mandatoryClauses: record["mandatoryClauseCount"] as? Int, objective: task.objective).isEmpty
                    if !risky { record["gatedChecks"] = "skipped (no risk signal)" }
                    if (task.examinerCheck ?? false) && risky {
                        changed += try await BatchExaminerStage.followUp(candidate: candidate, root: root, directory: dir,
                            model: model, objective: task.objective, originals: sourcesAtStart.filter { production.contains($0.key) }, visibleTests: visibleTests,
                            permitted: scope.editable, protected: protected, maxEdits: task.maxEdits, maxLines: task.maxLines,
                            editor: editor, isolated: isolated, evidence: isolation, budget: &budget, record: record)
                    }
                    if (task.exampleCheck ?? false) && risky {
                        await ExampleCheckStage.run(candidate: candidate, root: root, directory: dir, model: model,
                            objective: task.objective, originals: sourcesAtStart.filter { production.contains($0.key) },
                            visibleTests: visibleTests, permitted: scope.editable, record: record)
                    }
                    let current = try await RepairAcceptanceContract.capture(root: root, paths: task.protectedFiles)
                    guard current.protectedFiles == contract.protectedFiles else { throw RepairAcceptanceError.protectedFilesChanged }
                    try await ledger.end("test"); try await ledger.begin("requirementGate")
                    attemptRecord["verification"] = "PASS"; record.append("attempts", attemptRecord)
                    label(attempt, repaired: repaired, pass: true)
                    // Any recovery action means the result was recovered, never a first-pass success.
                    // Tests passing never finalizes: the independent Requirement Gate decides (BatchRequirementGate).
                    try BatchRequirementGate.open(record: record, output: output, key: key, objective: task.objective, clauses: clauses,
                        plan: plan, proposals: changed, protected: protected, builderModel: model,
                        testsPassedResult: budget.used.isEmpty ? "HARNESS_PASS" : "HARNESS_RECOVERED_SUCCESS")
                    record["modelResult"] = CanaryAcceptanceDecision.modelResult(testsPassed: true, independentSpecificationPassed: nil)
                    record["promotionEligible"] = false
                    record["focusedTests"] = "isolated SwiftPM PASS"; record["recoveryBudgetUsed"] = budget.used.map(\.rawValue)
                    try record.save(); try await ledger.end("requirementGate"); break attempts
                case .verificationFailed(let verdict):
                    try await ledger.end("test", succeeded: false)
                    attemptRecord["verificationFailureClass"] = verdict.kind.rawValue
                    attemptRecord["verification"] = "FAIL (requirements not met; details withheld from model)"
                    record.append("attempts", attemptRecord); label(attempt, repaired: repaired, pass: false)
                    let rolled = await rollback(tx, repairTx, repairState)
                    guard rolled == "PASS" else { try fail("verification", Failure.scope, rollback: rolled); break attempts }
                    Self.noteRollback(record, rolled)
                    if verdict.runtimeRepairEligible && attempt == 1 && budget.consume(.runtimeRepair) {
                        runtimePlan = plan
                        runtimeFeedback = RuntimeRepair.feedback(verdict: verdict, diff: CompilerRepair.renderDiff(changed))
                        previousDiff = RuntimeRepair.fingerprint(proposals)
                        record.append("recoveryActions", "runtimeRepair"); try record.save()
                        continue attempts
                    }
                    guard verdict.kind == .assertion, attempt == 1, budget.consume(.requirementReplan) else {
                        record["failureClass"] = "Verification (requirements not met)"
                        try fail("verification", Failure.scope, rollback: rolled); break attempts
                    }
                    record.append("recoveryActions", "requirementReplan"); try record.save()
                    feedback = RequirementCoverage.verificationFeedback(previousPlan: plan, diff: CompilerRepair.renderDiff(changed))
                    previousDiff = RuntimeRepair.fingerprint(proposals)
                    continue attempts
                }
            } catch {
                record.append("attempts", attemptRecord); label(attempt, repaired: repaired, pass: false)
                let rolled = await rollback(tx, repairTx, repairState)
                // After a passing build, an exception comes from the test run itself (timeout / interruption).
                let testStage = attemptRecord["isolatedBuild"] as? String == "PASS"
                record["failureClass"] = record["failureClass"] ?? (testStage ? "Test execution did not finish (timeout or interruption)" : "Compile")
                try fail(testStage ? "testExecution" : "compile", error, rollback: rolled); break attempts
            }
        }
        record["modelUsage"] = InferenceEnvironment.shared.usage; try record.save()
        try await ledger.stop(phase: record["phase"] as? String ?? "failed:unknown")
        print("Canary \(key): \(record["modelResult"] ?? "") / Harness \(record["harnessResult"] ?? ""). \(result.path)")
    }
}
