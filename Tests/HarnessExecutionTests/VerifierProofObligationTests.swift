import Foundation
import Testing
@testable import HarnessExecution

/// Synthetic, task-independent checks of Phase 3 relation extraction, proof obligations and Arm D
/// admission. Protected property: SATISFIED needs resolved obligations in a complete bounded graph
/// plus a valid Harness-owned receipt; anything unproven is UNCERTAIN.
struct VerifierProofObligationTests {
    typealias O = VerifierProofObligations
    let gate = """
    struct Gate {
        let policy: Policy
        func admit(_ value: Int) -> Bool {
            return passes(value)
        }
        func passes(_ value: Int) -> Bool {
            return policy.allows(value)
        }
        func unrelated() -> Int {
            return 99
        }
    }
    """
    let policy = """
    struct Policy {
        func allows(_ value: Int) -> Bool {
            if value >= Limits.floor { return true }
            return false
        }
    }
    """
    let limits = """
    enum Limits {
        static let floor = 5
    }
    """
    var files: [String: String] { ["Sources/Gate.swift": gate, "Sources/Policy.swift": policy, "Sources/Limits.swift": limits] }
    func index(_ f: [String: String]? = nil) -> VerifierRelationIndex { .init(production: f ?? files, protectedPaths: []) }
    func names(_ i: VerifierRelationIndex) -> Set<String> {
        let byID = Dictionary(uniqueKeysWithValues: i.nodes.map { ($0.id, $0.symbol) })
        return Set(i.edges.map { "\(byID[$0.from]!)→\(byID[$0.to]!):\($0.relationType.rawValue)" })
    }
    func prove(_ text: String, root: String = "Gate.admit", _ f: [String: String]? = nil) -> O.ClauseProof {
        let f = f ?? files
        let declared = f.values.reduce(into: Set<String>()) { $0.formUnion(ContextRelationships.declarations($1).all) }
        return O.prove(clause: .init(id: "C1", text: text), rootSymbol: root, index: index(f), declared: declared)
    }

    @Test func callerHelperAndHelperConstantAcrossFiles() {
        let edges = names(index())
        #expect(edges.contains("Gate.admit→Gate.passes:helperCall"))
        #expect(edges.contains("Gate.passes→Policy.allows:directCall"))      // property of declared type
        #expect(edges.contains("Policy.allows→Limits.floor:constantReference"))
        #expect(edges.contains("Gate.policy→Policy:referenceUse"))
    }

    @Test func validProofBundleResolvesBoundaryThroughConstantInAnotherFile() {
        let proof = prove("`passes` は値が 5 以上なら true を返して。", root: "Gate.passes")
        #expect(proof.proven, "\(proof.obligations) \(proof.gaps) \(proof.graphReasons)")
        #expect(proof.files == 3)
    }

    @Test func depthBoundLeavesGapAndIsNotProven() {
        // admit → passes → allows → floor is depth 3: over the bound of 2.
        let proof = prove("値が 5 以上なら true を返して。")
        #expect(!proof.proven)
        #expect(proof.gaps.contains("depthBound"))
    }

    @Test func otherInclusivityIsUnresolvedNotViolated() {
        let proof = prove("値が 5 を超えるなら true を返して。", root: "Gate.passes")
        #expect(!proof.proven)
        #expect(proof.obligations.contains { $0.kind == "boundary" && $0.status == .unresolved && $0.reason.contains("other inclusivity") })
    }

    @Test func equivalentExpressionsShareThePartition() {
        var f = files
        f["Sources/Policy.swift"] = policy.replacingOccurrences(of: "value >= Limits.floor", with: "Limits.floor <= value")
        #expect(prove("値が 5 以上なら true を返して。", root: "Gate.passes", f).proven)
        f["Sources/Policy.swift"] = """
        struct Policy {
            func allows(_ value: Int) -> Bool {
                return min(value, 60) == value
            }
        }
        """
        #expect(prove("`passes` は 60 以下を上限に判定して。", root: "Gate.passes", f).obligations.contains { $0.kind == "boundary" && $0.status == .resolved })
    }

    @Test func unrelatedLiteralInSameTypeIsNotEvidence() {
        let proof = prove("`passes` は 99 を返して。", root: "Gate.passes")
        #expect(!proof.proven)
        #expect(proof.obligations.contains { $0.kind == "requiredValueParticipates" && $0.status == .unresolved })
    }

    @Test func sameNameMethodInAnotherTypeIsNotSelected() {
        var f = files
        f["Sources/Other.swift"] = policy.replacingOccurrences(of: "Policy", with: "OtherPolicy").replacingOccurrences(of: "Limits.floor", with: "7")
        let edges = names(index(f))
        #expect(edges.contains("Gate.passes→Policy.allows:directCall"))
        #expect(!edges.contains { $0.contains("OtherPolicy.allows") && $0.hasPrefix("Gate.") })
        #expect(!prove("値が 7 以上なら true を返して。", root: "Gate.passes", f).proven)
    }

    @Test func overloadAmbiguityIsNeverAnEdge() {
        var f = files
        f["Sources/Policy.swift"] = """
        struct Policy {
            func allows(_ value: Int) -> Bool {
                return value >= Limits.floor
            }
            func allows(_ value: Double) -> Bool {
                return value >= 5.0
            }
        }
        """
        let i = index(f)
        #expect(!names(i).contains { $0.contains("Policy.allows") })
        #expect(!prove("値が 5 以上なら true を返して。", root: "Gate.passes", f).proven)
    }

    @Test func commentsStringsAndInterpolationDoNotCreateRelations() {
        var f = files
        f["Sources/Gate.swift"] = """
        struct Gate {
            let policy: Policy
            func passes(_ value: Int) -> Bool {
                // policy.allows(value) with Limits.floor
                let note = "policy.allows(\\(value)) Limits.floor 5"
                /* policy.allows(value) */
                return note.isEmpty
            }
        }
        """
        let edges = names(index(f))
        #expect(!edges.contains { $0.hasPrefix("Gate.passes→") })
        #expect(!prove("値が 5 以上なら true を返して。", root: "Gate.passes", f).proven)
    }

    @Test func missingRelationLeavesRequiredSymbolUnresolved() {
        let proof = prove("`passes` は `unrelated` を呼んで結果を返して。", root: "Gate.passes")
        #expect(!proof.proven)
        #expect(proof.obligations.contains { $0.kind == "requiredSymbolReachable" && $0.detail == "unrelated" && $0.status == .unresolved })
    }

    @Test func cyclicGraphTerminates() {
        let f = ["Sources/Loop.swift": """
        struct Loop {
            func a(_ n: Int) -> Int {
                return b(n)
            }
            func b(_ n: Int) -> Int {
                if n > 3 { return a(n - 1) }
                return 3
            }
        }
        """]
        let proof = prove("`a` は 3 を超えるとき繰り返して。", root: "Loop.a", f)
        #expect(proof.nodes == 2)
        #expect(proof.edges == 2)
    }

    @Test func fileBoundLeavesGap() {
        var f: [String: String] = [:]
        var calls: [String] = []
        for n in 1...6 {
            f["Sources/H\(n).swift"] = "enum H\(n) {\n    static func v() -> Int {\n        return \(n)\n    }\n}"
            calls.append("H\(n).v()")
        }
        f["Sources/Root.swift"] = "enum Root {\n    static func sum() -> Int {\n        return " + calls.joined(separator: " + ") + "\n    }\n}"
        let proof = prove("`sum` は 1 を含めて合計して。", root: "Root.sum", f)
        #expect(!proof.proven)
        #expect(proof.gaps.contains("fileBound"))
    }

    @Test func negationAndUnanchoredClausesAreUnsupported() {
        #expect(prove("値が 5 以上でない場合は false を返して。", root: "Gate.passes").obligations.contains { $0.kind == "negationPolarity" && $0.status == .unsupported })
        #expect(!prove("自然な挙動にして。", root: "Gate.passes").proven)
    }

    @Test func lexerKeepsInterpolationOpaqueAndSkipsPlainAttributes() throws {
        let tokens = try VerifierSourceTokens.scan("@MainActor struct A {\n    let s = \"a\\(b.c) done\"\n}")
        #expect(tokens.map(\.text) == ["struct", "A", "{", "let", "s", "=", "<literal>", "}"])
        #expect(throws: VerifierSourceTokens.Failure.self) { _ = try VerifierSourceTokens.scan("let s = \"\\(\"nested\")\"") }
        let ok = try VerifierSourceTokens.scan("@discardableResult\nfunc f() -> Int {\n    let s = \"\"\"\n    multi \\(x)\n    \"\"\"\n    return 1\n}")
        #expect(ok.filter { $0.text == "<literal>" }.count == 1)
        #expect(!ok.contains { $0.text == "x" || $0.text == "discardableResult" })
        #expect(throws: VerifierSourceTokens.Failure.self) { _ = try VerifierSourceTokens.scan("#if DEBUG\nlet a = 1\n#endif") }
    }

    // MARK: Arm D admission

    func admitD(_ text: String, claimSymbol: String = "passes", receipt: Bool = true, protected: Bool = true,
                fresh: [String: String] = ["t()": "passed"], phase1Final: RequirementVerification.Verdict = .UNCERTAIN,
                reasons: [String] = ["edge condition not evidenced in scope: 5"], f: [String: String]? = nil) -> VerifierArmD.Outcome {
        let claim = VerifierAdmission.Claim(id: "C1", claimedStatus: phase1Final == .VIOLATED ? .VIOLATED : .SATISFIED,
                                            file: "Sources/Gate.swift", symbol: claimSymbol, exactSupportingQuote: "q", rationale: "r")
        let decision = VerifierAdmission.ItemDecision(id: "C1", claimed: claim.claimedStatus, final: phase1Final, canonicalSymbol: claimSymbol,
            passed: ["fileExists", "symbolExists", "quoteExists", "quoteInScope", "relevant"], reasons: reasons)
        return VerifierArmD.admit(clauses: [.init(id: "C1", text: text)], requirements: [], production: f ?? files,
            protectedPaths: [], claims: [claim], phase1: [decision],
            execution: .init(receiptValid: receipt, protectedIntact: protected, freshResults: fresh, requiredTests: ["C1": ["t()"]], notes: []))
    }

    @Test func armDAdmitsOnlyWithProofAndTrustedReceipt() {
        #expect(admitD("`passes` は値が 5 以上なら true を返して。").final == .SATISFIED)
        #expect(admitD("`passes` は値が 5 以上なら true を返して。", receipt: false).final == .UNCERTAIN)
        #expect(admitD("`passes` は値が 5 以上なら true を返して。", protected: false).final == .UNCERTAIN)
    }

    @Test func armDUnresolvedObligationIsUncertain() {
        let outcome = admitD("`passes` は値が 6 以上なら true を返して。")
        #expect(outcome.final == .UNCERTAIN)
        #expect(outcome.items[0].layer == "proof")
    }

    @Test func armDNeverViolatesOnStaticContradictionAlone() {
        let outcome = admitD("値が 5 を超えるなら true を返して。", phase1Final: .VIOLATED, reasons: ["deterministic contradiction: clause requires > 5"])
        #expect(outcome.final == .UNCERTAIN)
    }

    @Test func armDFreshHarnessFailureIsViolation() {
        #expect(admitD("`passes` は値が 5 以上なら true を返して。", fresh: ["t()": "failed"]).final == .VIOLATED)
    }

    @Test func armDGroundedViolationDisputedByPassingTestsIsUncertain() {
        #expect(admitD("x", phase1Final: .VIOLATED, reasons: ["grounded violation claim"]).final == .UNCERTAIN)
        #expect(admitD("x", receipt: false, phase1Final: .VIOLATED, reasons: ["grounded violation claim"]).final == .VIOLATED)
    }

    @Test func armDUnknownRootIsUncertain() {
        #expect(admitD("`passes` は値が 5 以上なら true を返して。", claimSymbol: "missing").final == .UNCERTAIN)
    }

    /// Real isolated Build/Test → Harness-owned receipt → graph proof → Arm D; mutation afterwards
    /// invalidates the receipt and the same proof is no longer admitted.
    @Test func trustedReceiptAndGraphIntegration() async throws {
        let candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let base = candidate.appendingPathComponent("work/proof-graph-" + UUID().uuidString)
        let root = base.appendingPathComponent("fixture"), evidence = base.appendingPathComponent("evidence")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: base) }
        let test = "Tests/ProbeTests/GateAcceptance.swift"
        var package: [String: String] = [
            "Package.swift": """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "Probe", targets: [
                .target(name: "Probe"),
                .testTarget(name: "ProbeTests", dependencies: ["Probe"])
            ])
            """,
            test: "import Testing\n@testable import Probe\n@Test func gateThreshold() { #expect(Gate(policy: Policy()).passes(5)) }\n"]
        for (path, content) in files { package[path.replacingOccurrences(of: "Sources/", with: "Sources/Probe/")] = content }
        for (path, content) in package {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let adapter = IsolatedPackageExecution(candidate: candidate, root: root.resolvingSymlinksInPath(), taskID: "proof-graph", protectedPaths: [test])
        let issuer = VerifierExecutionReceipts(adapter: adapter, evidence: evidence.resolvingSymlinksInPath())
        let receipt = try await issuer.execute(requiredTests: ["gateThreshold()"])
        let production = package.filter { $0.key.hasPrefix("Sources/") }
        func decide(receiptValid: Bool) -> RequirementVerification.Verdict {
            let claim = VerifierAdmission.Claim(id: "C1", claimedStatus: .SATISFIED, file: "Sources/Probe/Gate.swift",
                                                symbol: "Gate.passes(_:)", exactSupportingQuote: "q", rationale: "r")
            let decision = VerifierAdmission.ItemDecision(id: "C1", claimed: .SATISFIED, final: .UNCERTAIN, canonicalSymbol: "passes",
                passed: ["fileExists", "symbolExists", "quoteExists", "quoteInScope", "relevant"], reasons: [])
            return VerifierArmD.admit(clauses: [.init(id: "C1", text: "`passes` は値が 5 以上なら true を返して。")], requirements: [],
                production: production, protectedPaths: [test], claims: [claim], phase1: [decision],
                execution: .init(receiptValid: receiptValid, protectedIntact: true, freshResults: ["gateThreshold()": "passed"],
                                 requiredTests: ["C1": ["gateThreshold()"]], notes: [])).final
        }
        var valid = (try? await issuer.validate(receipt, requiredTests: ["gateThreshold()"])) != nil
        #expect(valid)
        #expect(decide(receiptValid: valid) == .SATISFIED)
        try (files["Sources/Limits.swift"]!.replacingOccurrences(of: "5", with: "6"))
            .write(to: root.appendingPathComponent("Sources/Probe/Limits.swift"), atomically: true, encoding: .utf8)
        valid = (try? await issuer.validate(receipt, requiredTests: ["gateThreshold()"])) != nil
        #expect(!valid)
        #expect(decide(receiptValid: valid) == .UNCERTAIN)
    }
}
