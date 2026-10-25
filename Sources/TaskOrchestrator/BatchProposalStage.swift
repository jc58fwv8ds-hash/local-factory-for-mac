import Foundation
import HarnessCore
import HarnessExecution

/// Proposal prompt with an explicit split between EDITABLE targets and READ-ONLY
/// evidence, plus the structured Missing-Context channel (usable while budget remains).
enum BatchProposalStage {
    static func prompt(objective: String, editable: [String: String], readOnly: [String: String],
                       maxEdits: Int, maxLines: Int, appendOnly: [String], escalationAvailable: Bool) throws -> String {
        func json(_ files: [String: String]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: files, options: [.sortedKeys]), as: UTF8.self)
        }
        let request = escalationAvailable ? """
        If the task cannot be completed by editing only the EDITABLE files (for example a READ-ONLY file must change,
        or you need a file or symbol you have not been shown), do not guess: return
        {"edits":[],"context_request":{"file":"relative path or empty","symbol":"name or empty","why_needed":"...","relation":"how it relates to the task","operation":"edit or read"}}.
        """ : "No further context can be requested; work only with what is shown."
        return """
        \(objective)
        Return JSON only: {"edits":[{"operation":"replace_exact","file":"relative path","expected_old_text":"exact source anchor","new_text":"replacement"}]}.
        Edit ONLY files under EDITABLE. Files under READ-ONLY are evidence to read; never put them in edits.
        Never invent files, types or fields you have not been shown.
        \(request)
        At most \(maxEdits) edits and \(maxLines) total old+new lines. Preserve indentation. No tools.
        Each expected_old_text must occur exactly once in its file. To delete text, use replace_exact with new_text "".
        Append-only paths: \(appendOnly). For these use append_block with empty expected_old_text, never replace existing text.
        EDITABLE: \(try json(editable))
        READ-ONLY: \(try json(readOnly))
        """
    }

    enum Stop: Error { case rejected(String) }

    /// Proposal generation against the accepted plan. A context_request (or an edit to an
    /// existing non-editable file) may regenerate once, only via ContextEscalation evidence
    /// and only while the shared contextReplan budget remains.
    static func propose(directory: URL, plan: RequirementCoveragePlan, objective: String, model: String,
                        scope: inout BatchScope, sources: [String: String], protected: Set<String>,
                        appendOnly: [String], maxEdits: Int, maxLines: Int, root: URL,
                        editor: RecordedProjectFileEditor, budget: inout RequirementCoverage.Budget,
                        record: BatchRunRecord, runtimeFeedback: String? = nil, outputTokens: Int = 2048) async throws -> [FileChangeProposal] {
        let planJSON = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        var queue = ["proposal"], anchorFeedback: String?, formatFeedback: String?, tokens = outputTokens
        while !queue.isEmpty {
            let name = queue.removeFirst()
            let dir = directory.appendingPathComponent(name)
            let editableNow = scope.editable, readOnlyNow = scope.readOnly, tokensNow = tokens
            let notes = [formatFeedback, anchorFeedback].compactMap { $0 }
            let repairNote = notes.isEmpty ? nil : notes.joined(separator: "\n")
            let available = runtimeFeedback == nil && budget.allows(.contextReplan)
            record.increment("modelProposalCount"); try record.save()
            do {
                let proposals = try await RecordedBatchProposal(directory: dir).prepare(root: root, files: editableNow,
                    objective: objective, model: model, protected: protected, appendOnly: Set(appendOnly),
                    maxEdits: maxEdits, maxLines: maxLines, editor: editor) { originals in
                    let prompt = try Self.prompt(objective: objective, editable: originals,
                        readOnly: sources.filter { readOnlyNow.contains($0.key) }.mapValues {
                            EvidenceSnippet.select(source: $0, relevant: plan.requirements.flatMap(\.relevant_symbols)
                                .flatMap { $0.split(separator: ".").map(String.init) } + EvidenceSnippet.identifiers(objective).sorted()) }, maxEdits: maxEdits,
                        maxLines: maxLines, appendOnly: appendOnly, escalationAvailable: available)
                        + "\nAccepted requirement coverage plan (implement it): \(planJSON)"
                        + (runtimeFeedback.map { "\n" + $0 } ?? "") + (repairNote.map { "\n" + $0 } ?? "")
                    return try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                        messages: SharedContextMessages.messages(for: prompt), maximumOutputTokens: tokensNow, structuredOutput: .structuredEditBatch))
                }
                return proposals
            } catch {
                let batch = savedBatch(in: dir)
                if formatFeedback == nil, let problem = formatProblem(error, batch: batch, appendOnly: Set(appendOnly)),
                   budget.consume(.formatRepair) {
                    formatFeedback = problem.feedback
                    if problem.cutOff { tokens = outputTokens * 2 }
                    record.append("recoveryActions", "formatRepair(\(problem.cutOff ? "cutOff" : "appendToExisting"))"); try record.save()
                    queue.append(name + "-format"); continue
                }
                // Anchor repair: one re-proposal with deterministic match counts, inside the task recovery budget.
                if case StructuredEditError.ambiguousAnchor = error, anchorFeedback == nil, let batch,
                   case let report = batch.anchorReport(originals: sources.filter { editableNow.contains($0.key) }),
                   !report.isEmpty, budget.consume(.anchorRepair) {
                    anchorFeedback = "Your previous edits were rejected because an anchor did not occur exactly once:\n"
                        + report.joined(separator: "\n") + "\nReturn the complete corrected edit list."
                    record.append("recoveryActions", "anchorRepair"); record["anchorRepair"] = report; try record.save()
                    queue.append(name + "-anchor"); continue
                }
                let request = batch.flatMap { $0.context_request ?? ContextEscalation.implicitRequest(
                    fromEditsIn: $0, editable: Set(editableNow), sources: sources) }
                guard available, let request else { throw Stop.rejected(String(describing: error)) }
                let decision = ContextEscalation.evaluate(request, objective: objective, targets: editableNow,
                    contextSet: editableNow + readOnlyNow, sources: sources, protected: protected)
                record["escalation"] = ["request": ["file": request.file ?? "", "symbol": request.symbol ?? "",
                    "whyNeeded": request.why_needed, "relation": request.relation, "operation": request.operation,
                    "explicit": batch?.context_request != nil], "accepted": decision.accepted,
                    "addedToContext": decision.addToContext, "promotedToEditable": decision.promoteToEditable,
                    "evidence": decision.evidence, "rejection": decision.rejection ?? ""] as [String: Any]
                guard decision.accepted,
                      Set(decision.promoteToEditable).intersection(scope.nominationOnly).isEmpty,
                      budget.consume(.contextReplan) else {
                    try record.save(); throw Stop.rejected("escalation: \(decision.rejection ?? "budget exhausted")")
                }
                record.append("recoveryActions", "contextReplan(modelContextRequest)")
                scope.apply(.init(added: decision.addToContext, promoted: decision.promoteToEditable))
                record["permittedFiles"] = scope.editable; record["readOnlyEvidence"] = scope.readOnly; try record.save()
                queue.append("proposal-escalated")
            }
        }
        throw Stop.rejected("escalated proposal rejected")
    }

    /// A cut-off edit list (it did not decode, or the server reported finish_reason=length) or append_block on a file
    /// that is not append-only: both are the response's form, not its content, so one re-proposal can fix them.
    static func formatProblem(_ error: Error, batch: StructuredEditBatch?, appendOnly: Set<String>) -> (cutOff: Bool, feedback: String)? {
        if error is DecodingError || String(describing: error).contains("finish_reason=length") {
            return (true, "Your previous edit list was cut off before it ended. Return the complete list again, compactly: "
                + "keep each expected_old_text to the few lines that make it unique, and do not repeat unchanged code in new_text.")
        }
        guard case StructuredEditError.scopeViolation = error, let batch else { return nil }
        let misused = Set(batch.edits.filter { $0.operation == "append_block" && !appendOnly.contains($0.file) }.map(\.file))
        guard !misused.isEmpty else { return nil }
        return (false, "Your previous edits were rejected: append_block is only for the append-only paths, and "
            + "\(misused.sorted()) already exist. To add code to an existing file, use replace_exact: quote a short unique "
            + "anchor (for example the closing lines of the type the code belongs in) and put the anchor plus the new code in new_text.")
    }

    static func savedResponse(in directory: URL) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("checkpoint.json"))) as? [String: Any])?["response"] as? String
    }

    /// The saved raw response of a rejected proposal, if any.
    static func savedBatch(in directory: URL) -> StructuredEditBatch? {
        guard let checkpoint = try? JSONSerialization.jsonObject(with: Data(contentsOf:
                directory.appendingPathComponent("checkpoint.json"))) as? [String: Any],
              let response = checkpoint["response"] as? String else { return nil }
        return try? JSONDecoder().decode(StructuredEditBatch.self, from: Data(StructuredResponseText.jsonObject(in: response).utf8))
    }

    static func encode(_ entries: [ContextSelector.Entry], editable: Set<String>) -> [[String: Any]] {
        entries.map { ["path": $0.path, "role": $0.role.rawValue, "reasons": $0.reasons,
                       "relation": $0.relation, "score": $0.score, "editable": editable.contains($0.path)] }
    }
}
