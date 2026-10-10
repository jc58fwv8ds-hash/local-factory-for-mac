import Foundation
import Testing
@testable import HarnessExecution

/// Synthetic, task-independent checks of Phase 5 (Arm F): unresolved references invalidate an
/// obligation only when they lie on the evidence path it uses; off-path issues stay as diagnostics.
struct VerifierArmFTests {
    typealias F = VerifierProofObligationsF

    let mode = """
    enum Mode {
        case idle, venting, sealed
    }
    """
    let gauge = """
    struct Gauge {
        let ceiling = 80
    }
    """
    func valve(_ body: String) -> String {
        """
        struct Valve {
            let gauge: Gauge
            func check(_ m: Mode) -> Bool {
                return m == .sealed
            }
            func shouldVent(_ pressure: Int) -> Bool {
        \(body)
            }
        }
        """
    }
    func files(_ body: String, extra: [String: String] = [:]) -> [String: String] {
        ["Sources/Mode.swift": mode, "Sources/Gauge.swift": gauge, "Sources/Valve.swift": valve(body)].merging(extra) { a, _ in a }
    }
    let clean = """
            if pressure > gauge.ceiling { return true }
            return false
    """
    let clause = "`shouldVent` は圧力が 80 を超えたら true を返して。"

    func prove(_ text: String, _ f: [String: String], root: String = "Valve.shouldVent") -> F.ClauseProof {
        let g = VerifierRelationGraphF(production: f, protectedPaths: [])
        let declared = f.values.reduce(into: Set<String>()) { $0.formUnion(ContextRelationships.declarations($1).all) }
        return F.prove(clause: .init(id: "C1", text: text), primaryRoot: g.nodes.first { $0.symbol == root }?.id, graph: g, declared: declared)
    }
    func proveE(_ text: String, _ f: [String: String], root: String = "Valve.shouldVent") -> VerifierProofObligationsE.ClauseProof {
        let g = VerifierRelationGraphE(production: f, protectedPaths: [])
        let declared = f.values.reduce(into: Set<String>()) { $0.formUnion(ContextRelationships.declarations($1).all) }
        return VerifierProofObligationsE.prove(clause: .init(id: "C1", text: text), primaryRoot: g.nodes.first { $0.symbol == root }?.id, graph: g, declared: declared)
    }
    let offPath = """
            let probe = make()
            let noted = probe.ceiling
            if pressure > gauge.ceiling { return true }
            return false
    """

    @Test func baselineCleanProof() {
        let proof = prove(clause, files(clean))
        #expect(proof.proven, "\(proof.obligations) \(proof.gaps) \(proof.graphReasons)")
    }

    @Test func unusedUnresolvedReferenceDoesNotInvalidateValidPath() {
        let proof = prove(clause, files(offPath))
        #expect(proof.proven, "\(proof.obligations) \(proof.gaps) \(proof.graphReasons)")
        #expect(!proveE(clause, files(offPath)).proven)            // Arm E: node-wide gap
    }

    @Test func ignoredDiagnosticsAreRecorded() {
        let proof = prove(clause, files(offPath))
        #expect(!proof.ignoredDiagnosticIDs.isEmpty)
        #expect(proof.provenance.allSatisfy { $0.onPathIssueIDs.isEmpty })
    }

    @Test func unresolvedReferenceOnUsedPathIsUncertain() {
        let body = """
                let probe = make()
                if pressure > gauge.ceiling || probe.ceiling > 0 { return true }
                return false
        """
        let proof = prove(clause, files(body))
        #expect(!proof.proven)
        #expect(proof.provenance.contains { $0.pathResolutionStatus == "UNRESOLVED" })
    }

    @Test func ambiguousEdgeOnUsedPathIsUncertain() {
        let body = """
                if pressure > gauge.ceiling && check(.sealed) { return true }
                return false
        """
        let proof = prove(clause, files(body))
        #expect(!proof.proven)
        #expect(proof.provenance.contains { $0.pathResolutionStatus == "AMBIGUOUS" })
    }

    @Test func unrelatedContextualEnumGapIsOnlyADiagnostic() {
        let body = """
                let unused = check(.sealed)
                if pressure > gauge.ceiling { return true }
                return false
        """
        let proof = prove(clause, files(body))
        #expect(proof.proven, "\(proof.obligations) \(proof.gaps)")
        #expect(!proof.ignoredDiagnosticIDs.isEmpty)
    }

    @Test func contextualEnumGapOnRequiredPathIsUncertain() {
        let body = """
                if check(.sealed) { return false }
                return pressure > gauge.ceiling
        """
        let proof = prove("`shouldVent` は `sealed` のとき false を返して。", files(body))
        #expect(!proof.proven)
        #expect(proof.obligations.contains { $0.kind == "requiredSymbolReachable" && $0.detail == "sealed" && $0.status != .resolved }
                || proof.obligations.contains { $0.status != .resolved && $0.reason.contains("ambiguous") })
    }

    @Test func twoPathsDirtyAndCleanSelectsClean() {
        let body = """
                let probe = make()
                if probe.ceiling > 80 { return true }
                if pressure > 80 { return true }
                return false
        """
        let proof = prove(clause, files(body))
        #expect(proof.proven, "\(proof.obligations)")
        let boundary = proof.obligations.first { $0.kind == "boundary" }!
        let provenance = proof.provenance.first { $0.obligationID == boundary.id }!
        #expect(provenance.pathResolutionStatus == "RESOLVED_UNIQUE")
        #expect(!proof.ignoredDiagnosticIDs.isEmpty)                  // the dirty candidate's issue is kept as a diagnostic
    }

    @Test func cyclicUnrelatedUnresolvedRelationTerminates() {
        let extra = ["Sources/Loop.swift": """
        struct Loop {
            func ping(_ n: Int) -> Int {
                let x = make()
                return pong(x.ceiling)
            }
            func pong(_ n: Int) -> Int {
                return ping(n)
            }
        }
        """]
        let proof = prove(clause, files(clean, extra: extra))
        #expect(proof.proven)
    }

    @Test func boundExceededOnRequiredPathIsUncertain() {
        let chain = ["Sources/Chain.swift": """
        enum Chain {
            static func a() -> Int {
                return b()
            }
            static func b() -> Int {
                return c()
            }
            static func c() -> Int {
                return d() + 7
            }
            static func d() -> Int {
                return 1
            }
        }
        """]
        let proof = prove("`a` は 7 を加えた値を返して。", chain, root: "Chain.a")
        #expect(!proof.proven)
        #expect(proof.provenance.contains { $0.pathResolutionStatus == "OUT_OF_BOUND" })
    }

    @Test func validProofProvenanceIsAuditable() {
        let proof = prove(clause, files(clean))
        #expect(proof.proven)
        for p in proof.provenance {
            #expect(p.pathResolutionStatus == "RESOLVED_UNIQUE")
            #expect(p.traversedEdgeStatuses.allSatisfy { $0 == "RESOLVED_UNIQUE" })
            #expect(p.rootID != nil && !p.evidenceNodeIDs.isEmpty)
        }
        #expect(proof.proofStrength == .CONDITION_PARTICIPATION)
    }

    @Test func exclusivityRequestedButOnlyPresenceProvenIsUncertain() {
        let proof = prove("`shouldVent` は圧力が 80 を超えたときだけ true を返して。", files(clean))
        #expect(!proof.proven)
        #expect(proof.proofStrength == .EXCLUSIVITY_UNPROVEN)
        #expect(proof.unresolvedSemanticObligations.contains("exclusivity"))
    }

    @Test func argumentsAreScannedForReferences() {
        let withArg = """
                if check(Mode.sealed) { return false }
                return pressure > gauge.ceiling
        """
        let g2 = VerifierRelationGraphF(production: files(withArg), protectedPaths: [])
        let names = Dictionary(uniqueKeysWithValues: g2.nodes.map { ($0.id, $0.symbol) })
        #expect(g2.edges.contains { names[$0.from] == "Valve.shouldVent" && names[$0.to] == "Mode.sealed" })
    }

    @Test func armFKeepsAdmissionPolicy() {
        let f = files(offPath)
        let claim = VerifierAdmission.Claim(id: "C1", claimedStatus: .SATISFIED, file: "Sources/Valve.swift", symbol: "shouldVent", exactSupportingQuote: "q", rationale: "r")
        let decision = VerifierAdmission.ItemDecision(id: "C1", claimed: .SATISFIED, final: .UNCERTAIN, canonicalSymbol: "shouldVent",
            passed: ["fileExists", "symbolExists", "quoteExists", "quoteInScope", "relevant"], reasons: [])
        func admit(receipt: Bool = true, protected: Bool = true, fresh: String = "passed") -> RequirementVerification.Verdict {
            VerifierArmF.admit(clauses: [.init(id: "C1", text: clause)], requirements: [], production: f, protectedPaths: [], claims: [claim], phase1: [decision],
                execution: .init(receiptValid: receipt, protectedIntact: protected, freshResults: ["t()": fresh], requiredTests: ["C1": ["t()"]], notes: [])).final
        }
        #expect(admit() == .SATISFIED)
        #expect(admit(receipt: false) == .UNCERTAIN)
        #expect(admit(protected: false) == .UNCERTAIN)
        #expect(admit(fresh: "failed") == .VIOLATED)
    }
}
