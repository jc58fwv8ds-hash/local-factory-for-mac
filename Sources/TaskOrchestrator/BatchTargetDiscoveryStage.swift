import Foundation
import HarnessCore
import HarnessExecution

/// One bounded, read-only discovery cycle. The model supplies search language,
/// never a path or edit; repository evidence determines returned candidates.
enum BatchTargetDiscoveryStage {
    enum Stop: Error { case invalidRequest, noCandidates }

    static func discover(objective: String, clauses: [ObjectiveClause], model: String,
                         sources: [String: String], existing: [RepositorySymbolIndex.Match],
                         budget: inout TargetDiscoveryPolicy.Budget,
                         record: BatchRunRecord) async throws -> [RepositorySymbolIndex.Match] {
        guard budget.consume() else { throw Stop.invalidRequest }
        record["targetDiscoveryCount"] = budget.used
        let clauseJSON = clauses.filter(\.mandatoryCandidate).map { ["id": $0.clauseID, "text": $0.exactSourceText] }
        let prompt = """
        The repository target is not confidently identified for this objective: \(objective)
        Objective clauses: \(String(decoding: try JSONSerialization.data(withJSONObject: clauseJSON, options: [.sortedKeys]), as: UTF8.self))
        Return JSON only: {"search_terms":["identifier-like term"],"expected_symbol_kind":"type/function/property/test/etc","expected_behavior":"brief behavior","why_needed":"why repository search is required"}.
        Do not invent or name file paths. Do not propose edits. Use at most \(TargetDiscoveryRequest.maximumTerms) concise terms.
        \(TargetDiscoveryRequest.promptContract)
        """
        record.increment("modelTargetDiscoveryCalls"); try record.save()
        let response = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
            messages: [.init(role: .user, content: prompt)], maximumOutputTokens: 512,
            structuredOutput: .targetDiscoveryRequest))
        record["targetDiscoveryRawResponse"] = response
        try record.save()
        guard let request = try? JSONDecoder().decode(TargetDiscoveryRequest.self, from: Data(response.utf8)),
              let request = try? request.validated() else {
            record["targetDiscoveryRequestValidation"] = "REJECTED"
            try record.save()
            throw Stop.invalidRequest
        }
        record["targetDiscoveryRequestValidation"] = "PASS"
        let discovered = RepositorySymbolIndex(sources: sources).retrieve(clauses: clauses,
            searchTerms: request.search_terms, maximumFiles: TargetDiscoveryPolicy.maximumFiles)
        record["targetDiscoveryRequest"] = ["search_terms": request.search_terms,
            "expected_symbol_kind": request.expected_symbol_kind, "expected_behavior": request.expected_behavior,
            "why_needed": request.why_needed]
        record["discoveredCandidates"] = encode(discovered)
        try record.save()
        let new = discovered.filter { item in !existing.contains(where: { $0.file == item.file }) }
        guard !(new.isEmpty && existing.isEmpty) else { throw Stop.noCandidates }
        return discovered
    }

    static func encode(_ candidates: [RepositorySymbolIndex.Match]) -> [[String: Any]] {
        candidates.map { ["candidateFile": $0.file, "candidateSymbol": $0.symbol,
            "matchedClause": $0.clauseID, "clauseText": $0.clauseText,
            "evidenceType": $0.evidenceType, "score": $0.score, "reason": $0.reason] }
    }

}
