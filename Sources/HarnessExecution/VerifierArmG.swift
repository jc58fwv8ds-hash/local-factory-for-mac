import Foundation

/// Phase 6 Arm G = Arm F, unchanged (path-scoped proofs, receipts, bounds, relation extraction, claim
/// validation, protected-test policy, fail-closed admission), plus the Semantic Obligation Gate: a clause
/// whose Arm F proof is complete becomes SATISFIED only if every behavioural relation it names is
/// RELATION_PROVEN (or it is a pure declaration clause). Arm F stays as it is.
public enum VerifierArmG {
    public typealias Verdict = RequirementVerification.Verdict

    public struct ItemDecision: Codable, Equatable, Sendable {
        public let id: String
        public let final: Verdict
        public let layer: String
        public let reasons: [String]
        public let proof: VerifierProofObligationsF.ClauseProof?
        public let semantic: VerifierSemanticObligationsG.Result?
    }

    public struct Outcome: Codable, Equatable, Sendable {
        public let arm: String
        public let final: Verdict
        public let items: [ItemDecision]
        public let execution: VerifierArmD.Execution
        public let deterministicOnly: Bool
    }

    public static func admit(clauses: [RequirementVerification.Item], requirements: [RequirementVerification.Item],
                             production: [String: String], protectedPaths: Set<String>,
                             claims: [VerifierAdmission.Claim]?, phase1: [VerifierAdmission.ItemDecision]?,
                             execution: VerifierArmD.Execution) -> Outcome {
        let f = VerifierArmF.admit(clauses: clauses, requirements: requirements, production: production, protectedPaths: protectedPaths,
                                   claims: claims, phase1: phase1, execution: execution)
        let sources = VerifierRelationIndex.productionSources(production, protectedPaths: protectedPaths)
        let graph = VerifierRelationGraphF(production: sources, protectedPaths: protectedPaths)
        let declared = sources.values.reduce(into: Set<String>()) { $0.formUnion(ContextRelationships.declarations($1).all) }
        let texts = Dictionary((clauses + requirements).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items = f.items.map { item -> ItemDecision in
            // Arm F leaves every "only when" clause unsupported. Arm G may replace exactly that obligation with a
            // structural exclusivity proof; every other Arm F obligation, gate and path check must already hold.
            if item.final == .UNCERTAIN, item.layer == "proof", let proof = item.proof, let clause = texts[item.id],
               proof.gaps.isEmpty, !proof.obligations.isEmpty,
               proof.obligations.allSatisfy({ $0.status == .resolved || $0.kind == "exclusivity" }),
               proof.obligations.contains(where: { $0.kind == "exclusivity" }),
               proof.unresolvedSemanticObligations == ["exclusivity"] {
                let exclusivityIDs = Set(proof.obligations.filter { $0.kind == "exclusivity" }.map(\.id))
                let graphOnlyExclusivity = proof.graphReasons.allSatisfy { r in exclusivityIDs.contains { r == "unsupportedObligation:" + $0 } }
                let semantic = VerifierSemanticObligationsG.evaluate(clause: clause, proof: proof, graph: graph, declared: declared)
                if graphOnlyExclusivity, semantic.passes,
                   semantic.obligations.contains(where: { $0.relationType == .exclusivity && $0.resolutionStatus == .RELATION_PROVEN }) {
                    return .init(id: item.id, final: .SATISFIED, layer: "all", reasons: [], proof: proof, semantic: semantic)
                }
                let open = semantic.obligations.filter { $0.resolutionStatus != .RELATION_PROVEN }.map { "\($0.relationType.rawValue): \($0.resolutionStatus.rawValue) (\($0.detail))" }
                return .init(id: item.id, final: .UNCERTAIN, layer: "semantic", reasons: open.isEmpty ? item.reasons : open, proof: proof, semantic: semantic)
            }
            guard item.final == .SATISFIED, let proof = item.proof, let clause = texts[item.id] else {
                // Anything Arm F did not admit keeps Arm F's decision (including VIOLATED paths).
                let semantic = item.proof.flatMap { p in texts[item.id].map { VerifierSemanticObligationsG.evaluate(clause: $0, proof: p, graph: graph, declared: declared) } }
                return .init(id: item.id, final: item.final, layer: item.layer, reasons: item.reasons, proof: item.proof, semantic: semantic)
            }
            let semantic = VerifierSemanticObligationsG.evaluate(clause: clause, proof: proof, graph: graph, declared: declared)
            guard semantic.passes else {
                let open = semantic.obligations.filter { $0.resolutionStatus != .RELATION_PROVEN }.map { "\($0.relationType.rawValue): \($0.resolutionStatus.rawValue) (\($0.detail))" }
                return .init(id: item.id, final: .UNCERTAIN, layer: "semantic", reasons: open, proof: proof, semantic: semantic)
            }
            return .init(id: item.id, final: .SATISFIED, layer: "all", reasons: [], proof: proof, semantic: semantic)
        }
        let final: Verdict = items.contains { $0.final == .VIOLATED } ? .VIOLATED
            : items.isEmpty || items.contains { $0.final == .UNCERTAIN } ? .UNCERTAIN : .SATISFIED
        return .init(arm: "G", final: final, items: items, execution: execution, deterministicOnly: f.deterministicOnly)
    }
}
