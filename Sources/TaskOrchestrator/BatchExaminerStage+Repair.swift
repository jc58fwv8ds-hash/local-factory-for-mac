import Foundation
import HarnessCore
import HarnessExecution

/// The builder's one fix after a confirmed examiner finding (split out of BatchExaminerStage.swift, 2026-10-18).
extension BatchExaminerStage {
    /// 4. Up to two fixes by the builder, which may decline. A fix is kept only if it builds, the package's tests pass and the
    /// confirmed examiner tests now pass (b5-04: an off-target fix passed the package's tests and was kept while the examined
    /// bug remained). After a first fix that leaves them failing, the builder sees the new result once; otherwise every
    /// examiner fix is rolled back and the tested state stands.
    static func repair(_ finding: Finding, root: URL, directory: URL, model: String, objective: String, permitted: [String],
                       protected: Set<String>, maxEdits: Int, maxLines: Int, editor: RecordedProjectFileEditor,
                       isolated: IsolatedPackageExecution, evidence: URL, budget: inout RequirementCoverage.Budget,
                       record: BatchRunRecord) async throws -> [FileChangeProposal] {
        let (confirmed, verdicts, examples) = (finding.confirmed, finding.verdicts, finding.examples)
        func note(_ values: [String: Any]) throws { record["examinerCheck"] = values; try record.save() }
        let files = permitted.filter { $0.hasPrefix("Sources/") && !protected.contains($0) }
        var feedback = finding.feedback, applied: [RecoverableFileBatch] = [], accepted: [FileChangeProposal] = []
        var outcome = ""
        func rollbackAll() async throws { for t in applied.reversed() { _ = try await t.run(root: root, direction: .rollback) } }
        for round in 1...2 {
            let suffix = round == 1 ? "" : "-\(round)"
            // Diagnose before fixing (b5-04: without it the builder twice "fixed" the trailing '-' the request talked about,
            // while the failing result "l-eading-spaces" came from the leading one; with it, one fix passed the holdout).
            let diagnosis: String
            do {
                let current = try files.reduce(into: [String: String]()) { $0[$1] = try String(contentsOf: root.appendingPathComponent($1), encoding: .utf8) }
                let map = String(decoding: try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]), as: UTF8.self)
                let ask = objective + "\n" + feedback.components(separatedBy: "\n\nIf the request asks")[0]
                    .components(separatedBy: "\n\nFind the actual cause")[0]
                    + "\n\nDo not write code yet. Trace the failing input through the current code step by step and name the exact "
                    + "line(s) that produce the wrong value, and why. At most 8 short lines.\nEDITABLE: \(map)"
                diagnosis = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                    messages: SharedContextMessages.messages(for: ask), maximumOutputTokens: 700))
            } catch { diagnosis = "" }
            let fixFeedback = diagnosis.isEmpty ? feedback : feedback + "\n\nDiagnosis of the cause (from tracing the code):\n" + diagnosis
            record.increment("modelProposalCount")
            let proposals: [FileChangeProposal]
            do {
                proposals = try await RecordedBatchProposal(directory: directory.appendingPathComponent("examiner-proposal" + suffix)).prepare(
                    root: root, files: files, objective: objective, model: model, protected: protected, appendOnly: [],
                    maxEdits: maxEdits, maxLines: maxLines, editor: editor) { [fixFeedback] current in
                    let map = String(decoding: try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]), as: UTF8.self)
                    let prompt = """
                    \(objective)
                    \(fixFeedback)
                    Return JSON only: {"edits":[{"operation":"replace_exact","file":"relative path","expected_old_text":"exact source anchor","new_text":"replacement"}]}.
                    Each expected_old_text must occur exactly once in its file. Preserve indentation. No tools.
                    EDITABLE: \(map)
                    """
                    return try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                        messages: SharedContextMessages.messages(for: prompt), maximumOutputTokens: 2048, structuredOutput: .structuredEditBatch))
                }
            } catch {
                outcome = "builderDeclinedOrUnusable round \(round) (\(error))"; break
            }
            let transaction = RecoverableFileBatch(directory: directory.appendingPathComponent("transaction-examiner" + suffix))
            try await transaction.prepare(root: root, proposals: proposals, allowed: Set(files), protected: protected)
            _ = try await transaction.run(root: root, direction: .resume)
            applied.append(transaction)
            if try await BatchCompilerRepair.compile(isolated, evidence: evidence, root: root) != nil {
                outcome = "rolledBack round \(round) (does not compile)"; break
            }
            guard case .passed = try await BatchCompilerRepair.test(isolated, evidence: evidence) else {
                outcome = "rolledBack round \(round) (tests fail)"; break
            }
            accepted += proposals
            let recheck = try await runExam(finding.tests, candidate: finding.candidate, root: root, target: finding.target,
                visibleTests: finding.visibleTests, evidence: directory.appendingPathComponent("examiner-recheck\(suffix)"))
            let stillFailing = confirmed.filter { name in
                !SecondCandidate.matches(#"✔ Test (examiner_\w+)\(\) passed"#, in: recheck).contains(name)
            }
            if stillFailing.isEmpty {
                _ = budget.consume(.examinerRepair)
                record.append("recoveryActions", "examinerRepair")
                try note(["outcome": "applied round \(round)", "confirmed": confirmed, "verdicts": verdicts, "examples": examples,
                          "files": accepted.map(\.relativePath)])
                return accepted
            }
            outcome = "rolledBack round \(round) (examiner tests still fail: \(stillFailing.joined(separator: ", ")))"
            feedback = "Your previous fix did not make the reviewer's test pass. After it, the test still fails:\n"
                + stillFailing.map { testBody($0, in: finding.tests) + "\n" + failureDetail($0, in: recheck) }.joined(separator: "\n\n")
                + "\n\nFind the actual cause in the code and fix it. If the test expects something the request does not ask for, "
                + "return {\"edits\":[]}."
        }
        try await rollbackAll()
        try note(["outcome": outcome, "confirmed": confirmed, "verdicts": verdicts, "examples": examples])
        return []
    }
}
