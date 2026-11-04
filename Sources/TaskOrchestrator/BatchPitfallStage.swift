import Foundation
import HarnessCore
import HarnessExecution

/// After the tests pass (and after the caller follow-up): if the code the change added has a known Swift pitfall
/// (SwiftPitfalls), one follow-up proposal may fix it. Only edits inside the listed functions are kept; the result is kept
/// only if it builds and the tests still pass, otherwise it is rolled back and the tests-passed state stands.
enum BatchPitfallStage {
    /// The caller follow-up (BatchCallerStage), then this one on the code as it stands after it.
    static func afterCallers(root: URL, directory: URL, model: String, objective: String, changed: [FileChangeProposal],
                             permitted: [String], protected: Set<String>, maxEdits: Int, maxLines: Int,
                             editor: RecordedProjectFileEditor, isolated: IsolatedPackageExecution, evidence: URL,
                             budget: inout RequirementCoverage.Budget, record: BatchRunRecord) async throws -> [FileChangeProposal] {
        let callers = try await BatchCallerStage.followUp(root: root, directory: directory, model: model, objective: objective,
            changed: changed, permitted: permitted, protected: protected, maxEdits: maxEdits, maxLines: maxLines, editor: editor,
            isolated: isolated, evidence: evidence, budget: &budget, record: record)
        return try await callers + followUp(root: root, directory: directory, model: model, objective: objective,
            changed: changed + callers, permitted: permitted, protected: protected, maxEdits: maxEdits, maxLines: maxLines,
            editor: editor, isolated: isolated, evidence: evidence, budget: &budget, record: record)
    }

    static func followUp(root: URL, directory: URL, model: String, objective: String, changed: [FileChangeProposal],
                         permitted: [String], protected: Set<String>, maxEdits: Int, maxLines: Int,
                         editor: RecordedProjectFileEditor, isolated: IsolatedPackageExecution, evidence: URL,
                         budget: inout RequirementCoverage.Budget, record: BatchRunRecord) async throws -> [FileChangeProposal] {
        var before: [String: String] = [:], after: [String: String] = [:]
        for proposal in changed where before[proposal.relativePath] == nil { before[proposal.relativePath] = proposal.originalContent }
        for path in permitted where path.hasPrefix("Sources/") && !protected.contains(path) {
            guard let now = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { continue }
            after[path] = now
            if before[path] == nil { before[path] = now }
        }
        let hits = Array(SwiftPitfalls.find(before: before, after: after).prefix(6))
        guard !hits.isEmpty else { return [] }
        func note(_ outcome: String) throws {
            record["pitfallCheck"] = ["hits": hits.map { ["file": $0.file, "function": $0.declaration.qualifiedName, "kinds": $0.kinds.map(\.rawValue)] },
                                     "outcome": outcome] as [String: Any]
            try record.save()
        }
        guard budget.allows(.pitfallRepair) else { try note("budgetExhausted"); return [] }
        let files = Array(Set(hits.map(\.file))).sorted()
        let proposals: [FileChangeProposal]
        record.increment("modelProposalCount")
        do {
            proposals = try await RecordedBatchProposal(directory: directory.appendingPathComponent("pitfall-proposal")).prepare(
                root: root, files: files, objective: objective, model: model, protected: protected, appendOnly: [],
                maxEdits: maxEdits, maxLines: maxLines, editor: editor) { current in
                let map = String(decoding: try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]), as: UTF8.self)
                let prompt = """
                \(objective)
                \(SwiftPitfalls.feedback(hits))
                Return JSON only: {"edits":[{"operation":"replace_exact","file":"relative path","expected_old_text":"exact source anchor","new_text":"replacement"}]}.
                Each expected_old_text must occur exactly once in its file. Preserve indentation. No tools.
                EDITABLE: \(map)
                """
                let response = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                    messages: SharedContextMessages.messages(for: prompt), maximumOutputTokens: 2048, structuredOutput: .structuredEditBatch))
                guard let batch = try? JSONDecoder().decode(StructuredEditBatch.self, from: Data(StructuredResponseText.jsonObject(in: response).utf8))
                else { return response }
                let kept = batch.edits.filter { edit in
                    !edit.expected_old_text.isEmpty && hits.contains { $0.file == edit.file && $0.declaration.text.contains(edit.expected_old_text) }
                }
                return String(decoding: try JSONEncoder().encode(StructuredEditBatch(edits: kept)), as: UTF8.self)
            }
        } catch {
            // An empty edit list (none needed, or every edit was outside the list) or an unusable batch: keep the tested state.
            try note("noFollowUp (\(error))"); return []
        }
        let transaction = RecoverableFileBatch(directory: directory.appendingPathComponent("transaction-pitfall"))
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
        _ = budget.consume(.pitfallRepair)
        record.append("recoveryActions", "pitfallRepair")
        try note("applied (\(proposals.map(\.relativePath).joined(separator: ", ")))")
        return proposals
    }
}
