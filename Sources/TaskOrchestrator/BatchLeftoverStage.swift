import Foundation
import HarnessCore
import HarnessExecution

/// After the tests pass: if code the change replaced still exists in a production file it did not touch (LeftoverClones),
/// one follow-up proposal may update those places. The follow-up is kept only if it builds and the tests still pass;
/// otherwise it is rolled back and the tests-passed state stands, so a false alarm cannot make the result worse.
enum BatchLeftoverStage {
    static func followUp(root: URL, directory: URL, model: String, objective: String, changed: [FileChangeProposal],
                         permitted: [String], protected: Set<String>, maxEdits: Int, maxLines: Int,
                         editor: RecordedProjectFileEditor, isolated: IsolatedPackageExecution, evidence: URL,
                         budget: inout RequirementCoverage.Budget, record: BatchRunRecord) async throws -> [FileChangeProposal] {
        var changes: [String: (before: String, after: String)] = [:]
        for proposal in changed where changes[proposal.relativePath] == nil {
            let now = try String(contentsOf: root.appendingPathComponent(proposal.relativePath), encoding: .utf8)
            changes[proposal.relativePath] = (proposal.originalContent, now)
        }
        var sources: [String: String] = [:]
        for path in permitted where path.hasPrefix("Sources/") && !protected.contains(path) {
            sources[path] = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let hits = LeftoverClones.find(changes: changes, sources: sources).filter { permitted.contains($0.file) }
        guard !hits.isEmpty else { return [] }
        func note(_ outcome: String) throws {
            record["leftoverCheck"] = ["hits": hits.map { ["file": $0.file, "line": $0.line, "text": $0.text, "replacedIn": $0.replacedIn] },
                                       "outcome": outcome] as [String: Any]
            try record.save()
        }
        guard budget.allows(.leftoverRepair) else { try note("budgetExhausted"); return [] }
        let files = Array(Set(hits.map(\.file) + changes.keys)).sorted()
        let proposals: [FileChangeProposal]
        record.increment("modelProposalCount")
        do {
            proposals = try await RecordedBatchProposal(directory: directory.appendingPathComponent("leftover-proposal")).prepare(
                root: root, files: files, objective: objective, model: model, protected: protected, appendOnly: [],
                maxEdits: maxEdits, maxLines: maxLines, editor: editor) { current in
                let map = String(decoding: try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]), as: UTF8.self)
                let prompt = """
                \(objective)
                \(LeftoverClones.feedback(hits))
                Return JSON only: {"edits":[{"operation":"replace_exact","file":"relative path","expected_old_text":"exact source anchor","new_text":"replacement"}]}.
                Each expected_old_text must occur exactly once in its file. Preserve indentation. No tools.
                EDITABLE: \(map)
                """
                return try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                    messages: SharedContextMessages.messages(for: prompt), maximumOutputTokens: 2048, structuredOutput: .structuredEditBatch))
            }
        } catch {
            // An empty edit list (the model judged the places out of scope) or an unusable batch: keep the tested state.
            try note("noFollowUp (\(error))"); return []
        }
        let transaction = RecoverableFileBatch(directory: directory.appendingPathComponent("transaction-leftover"))
        try await transaction.prepare(root: root, proposals: proposals, allowed: Set(files), protected: protected)
        _ = try await transaction.run(root: root, direction: .resume)
        if try await BatchCompilerRepair.compile(isolated, evidence: evidence, root: root) != nil {
            _ = try await transaction.run(root: root, direction: .rollback)
            try note("rolledBack (does not compile)"); return []
        }
        guard case .passed = try await BatchCompilerRepair.test(isolated, evidence: evidence) else {
            _ = try await transaction.run(root: root, direction: .rollback)
            try note("rolledBack (tests fail)"); return []
        }
        _ = budget.consume(.leftoverRepair)
        record.append("recoveryActions", "leftoverRepair")
        try note("applied (\(proposals.map(\.relativePath).joined(separator: ", ")))")
        return proposals
    }
}
