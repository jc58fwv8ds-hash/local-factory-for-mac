import Foundation

/// Phase 5 Arm F = Arm E's admission policy, unchanged, with path-scoped proofs (VerifierProofObligationsF
/// over VerifierRelationGraphF). Arm E stays as it is.
public enum VerifierArmF {
    public typealias Verdict = RequirementVerification.Verdict

    public struct ItemDecision: Codable, Equatable, Sendable {
        public let id: String
        public let final: Verdict
        public let layer: String
        public let reasons: [String]
        public let proof: VerifierProofObligationsF.ClauseProof?
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
        let items = clauses + requirements
        func done(_ decisions: [ItemDecision], deterministic: Bool) -> Outcome {
            let final: Verdict = decisions.contains { $0.final == .VIOLATED } ? .VIOLATED
                : decisions.isEmpty || decisions.contains { $0.final == .UNCERTAIN } ? .UNCERTAIN : .SATISFIED
            return .init(arm: "F", final: final, items: decisions, execution: execution, deterministicOnly: deterministic)
        }
        guard execution.protectedIntact else {
            return done(items.map { .init(id: $0.id, final: .UNCERTAIN, layer: "integrity", reasons: ["protected test changed"], proof: nil) }, deterministic: true)
        }
        let failing = Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, (execution.requiredTests[item.id] ?? []).filter { execution.freshResults[$0] == "failed" })
        })
        if failing.values.contains(where: { !$0.isEmpty }) {
            return done(items.map { item in
                failing[item.id]!.isEmpty
                    ? .init(id: item.id, final: .UNCERTAIN, layer: "tests", reasons: ["not decided: another clause is contradicted"], proof: nil)
                    : .init(id: item.id, final: .VIOLATED, layer: "tests", reasons: ["Harness run failed: " + failing[item.id]!.joined(separator: ",")], proof: nil)
            }, deterministic: true)
        }
        let production = VerifierRelationIndex.productionSources(production, protectedPaths: protectedPaths)
        let graph = VerifierRelationGraphF(production: production, protectedPaths: protectedPaths)
        let declared = production.values.reduce(into: Set<String>()) { $0.formUnion(ContextRelationships.declarations($1).all) }
        let claimByID = Dictionary((claims ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let phase1ByID = Dictionary((phase1 ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let decisions = items.map { item -> ItemDecision in
            guard let decision = phase1ByID[item.id], let claim = claimByID[item.id] else {
                return .init(id: item.id, final: .UNCERTAIN, layer: "claim", reasons: ["no validated model claim"], proof: nil)
            }
            let mapped = execution.requiredTests[item.id] ?? []
            let testsPass = execution.receiptValid && !mapped.isEmpty && mapped.allSatisfy { execution.freshResults[$0] == "passed" }
            switch decision.final {
            case .VIOLATED:
                if decision.reasons.contains(where: { $0.hasPrefix("deterministic contradiction") }) {
                    return .init(id: item.id, final: .UNCERTAIN, layer: "contradiction",
                                 reasons: decision.reasons + ["static contradiction alone is not a violation"], proof: nil)
                }
                if testsPass {
                    return .init(id: item.id, final: .UNCERTAIN, layer: "conflict", reasons: decision.reasons + ["disputed by passing Harness-run tests"], proof: nil)
                }
                return .init(id: item.id, final: .VIOLATED, layer: "claim", reasons: decision.reasons, proof: nil)
            case .UNCERTAIN, .SATISFIED:
                guard claim.claimedStatus == .SATISFIED, VerifierArmD.validatedClaim.isSubset(of: Set(decision.passed)),
                      let canonical = decision.canonicalSymbol else {
                    return .init(id: item.id, final: .UNCERTAIN, layer: "claim", reasons: decision.reasons.isEmpty ? ["claim not validated"] : decision.reasons, proof: nil)
                }
                guard execution.receiptValid else {
                    return .init(id: item.id, final: .UNCERTAIN, layer: "execution", reasons: ["no valid Harness-owned receipt for the final inputs"] + execution.notes, proof: nil)
                }
                // Primary root: the claimed declaration in the claimed file when unique; otherwise the
                // prover derives roots from clause-named symbols only.
                let roots = graph.nodes.filter { $0.file == claim.file && ($0.symbol == canonical || graph.terminalNames[$0.id] == canonical) }
                let proof = VerifierProofObligationsF.prove(clause: item, primaryRoot: roots.count == 1 ? roots[0].id : nil, graph: graph,
                                                            declared: declared, protectedPaths: protectedPaths)
                guard proof.proven else {
                    let open = proof.obligations.filter { $0.status != .resolved }.map { "\($0.kind)[\($0.detail)]: \($0.reason)" }
                    return .init(id: item.id, final: .UNCERTAIN, layer: "proof",
                                 reasons: open + proof.gaps.map { "gap: " + $0 } + (proof.graphValid ? [] : proof.graphReasons.map { "graph: " + $0 }),
                                 proof: proof)
                }
                return .init(id: item.id, final: .SATISFIED, layer: "all", reasons: [], proof: proof)
            }
        }
        return done(decisions, deterministic: false)
    }
}
