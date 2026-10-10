import Foundation

/// Phase 3 Arm D: Phase 1 claim validation + bounded Proof Bundle (relations + obligations) +
/// Harness-owned execution evidence. SATISFIED only when every mandatory gate agrees; a single
/// unresolved obligation, invalid graph, bound gap or missing trusted receipt is UNCERTAIN.
/// A static/numeric contradiction alone never yields VIOLATED here.
public enum VerifierArmD {
    public typealias Verdict = RequirementVerification.Verdict

    /// Produced by the Harness runner from its own isolated executions, never from case data.
    public struct Execution: Codable, Equatable, Sendable {
        public let receiptValid: Bool
        public let protectedIntact: Bool
        /// Required-test results of the latest Harness run on the final inputs (fresh), if any.
        public let freshResults: [String: String]
        public let requiredTests: [String: [String]]
        public let notes: [String]
        public init(receiptValid: Bool, protectedIntact: Bool, freshResults: [String: String],
                    requiredTests: [String: [String]], notes: [String]) {
            self.receiptValid = receiptValid; self.protectedIntact = protectedIntact; self.freshResults = freshResults
            self.requiredTests = requiredTests; self.notes = notes
        }
    }

    public struct ItemDecision: Codable, Equatable, Sendable {
        public let id: String
        public let final: Verdict
        public let layer: String
        public let reasons: [String]
        public let proof: VerifierProofObligations.ClauseProof?
    }

    public struct Outcome: Codable, Equatable, Sendable {
        public let arm: String
        public let final: Verdict
        public let items: [ItemDecision]
        public let execution: Execution
        public let deterministicOnly: Bool
    }

    static let validatedClaim: Set<String> = ["fileExists", "symbolExists", "quoteExists", "quoteInScope", "relevant"]

    public static func admit(clauses: [RequirementVerification.Item], requirements: [RequirementVerification.Item],
                             production: [String: String], protectedPaths: Set<String>,
                             claims: [VerifierAdmission.Claim]?, phase1: [VerifierAdmission.ItemDecision]?,
                             execution: Execution) -> Outcome {
        let items = clauses + requirements
        func done(_ decisions: [ItemDecision], deterministic: Bool) -> Outcome {
            let final: Verdict = decisions.contains { $0.final == .VIOLATED } ? .VIOLATED
                : decisions.isEmpty || decisions.contains { $0.final == .UNCERTAIN } ? .UNCERTAIN : .SATISFIED
            return .init(arm: "D", final: final, items: decisions, execution: execution, deterministicOnly: deterministic)
        }
        // Integrity first: tampered protected tests invalidate every downstream signal.
        guard execution.protectedIntact else {
            return done(items.map { .init(id: $0.id, final: .UNCERTAIN, layer: "integrity", reasons: ["protected test changed"], proof: nil) },
                        deterministic: true)
        }
        // A required test that fails on the final inputs in a Harness run contradicts its clause.
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
        let index = VerifierRelationIndex(production: production, protectedPaths: protectedPaths)
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
                                 reasons: decision.reasons + ["static contradiction alone is not a violation in Arm D"], proof: nil)
                }
                if testsPass {
                    return .init(id: item.id, final: .UNCERTAIN, layer: "conflict",
                                 reasons: decision.reasons + ["disputed by passing Harness-run tests"], proof: nil)
                }
                return .init(id: item.id, final: .VIOLATED, layer: "claim", reasons: decision.reasons, proof: nil)
            case .UNCERTAIN, .SATISFIED:
                guard claim.claimedStatus == .SATISFIED, validatedClaim.isSubset(of: Set(decision.passed)),
                      let canonical = decision.canonicalSymbol else {
                    return .init(id: item.id, final: .UNCERTAIN, layer: "claim", reasons: decision.reasons.isEmpty ? ["claim not validated"] : decision.reasons, proof: nil)
                }
                guard execution.receiptValid else {
                    return .init(id: item.id, final: .UNCERTAIN, layer: "execution", reasons: ["no valid Harness-owned receipt for the final inputs"] + execution.notes, proof: nil)
                }
                // The root is the claimed declaration in the claimed file; it must be unique.
                let roots = index.nodes.filter { $0.file == claim.file && ($0.symbol == canonical || $0.symbol.hasSuffix("." + canonical)) }
                guard roots.count == 1 else {
                    return .init(id: item.id, final: .UNCERTAIN, layer: "relations",
                                 reasons: ["claimed declaration is missing, ambiguous or unsupported in the relation index"], proof: nil)
                }
                let proof = VerifierProofObligations.prove(clause: item, rootSymbol: roots[0].symbol, index: index,
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
