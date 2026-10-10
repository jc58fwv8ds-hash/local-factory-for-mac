import Foundation
import Testing
@testable import HarnessExecution

/// Synthetic, task-independent checks of Phase 4 (Arm E): enum cases, typed member access, bounded
/// multi-root proofs. Protected property: a wider graph never resolves an obligation by itself and
/// every edge used in a proof is RESOLVED_UNIQUE.
struct VerifierArmETests {
    typealias G = VerifierRelationGraphE
    typealias O = VerifierProofObligationsE

    let light = """
    enum Light {
        case red, amber
        case green
        func next() -> Light {
            switch self {
            case .red: return .green
            case .green: return .amber
            case .amber: return .red
            }
        }
    }
    """
    let crossing = """
    struct Crossing {
        let light: Light
        let limits: Limits
        func mayCross(_ waiting: Int) -> Bool {
            if light == .green { return true }
            return waiting >= limits.patience
        }
        func advanced() -> Light {
            return light.next()
        }
    }
    """
    let limits = """
    struct Limits {
        let patience = 30
    }
    """
    var files: [String: String] { ["Sources/Light.swift": light, "Sources/Crossing.swift": crossing, "Sources/Limits.swift": limits] }
    func graph(_ f: [String: String]? = nil) -> G { G(production: f ?? files, protectedPaths: []) }
    func edges(_ g: G) -> Set<String> {
        let names = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0.symbol) })
        return Set(g.edges.map { "\(names[$0.from]!)→\(names[$0.to]!)" })
    }
    func node(_ g: G, _ symbol: String) -> String? { g.nodes.first { $0.symbol == symbol }?.id }
    func prove(_ text: String, root: String?, _ f: [String: String]? = nil, bounds: O.Bounds = .phase4) -> O.ClauseProof {
        let f = f ?? files, g = graph(f)
        let declared = f.values.reduce(into: Set<String>()) { $0.formUnion(ContextRelationships.declarations($1).all) }
        return O.prove(clause: .init(id: "C1", text: text), primaryRoot: root.flatMap { node(g, $0) }, graph: g, declared: declared, bounds: bounds)
    }

    @Test func enumCasesAreNodes() {
        let g = graph()
        #expect(["Light.red", "Light.amber", "Light.green"].allSatisfy { node(g, $0) != nil })
        #expect(edges(g).contains("Light.green→Light"))
        #expect(g.nodes.first { $0.symbol == "Light.red" }?.evidenceType == "enumCase")
    }

    @Test func qualifiedAndSwitchCaseReferences() {
        var f = files
        f["Sources/Reset.swift"] = "enum Reset {\n    static func initial() -> Light {\n        return Light.red\n    }\n}"
        let e = edges(graph(f))
        #expect(e.contains("Reset.initial→Light.red"))              // Type.caseName
        #expect(e.contains("Light.next→Light.amber"))               // switch self / return .case
        #expect(graph(f).edges.allSatisfy { $0.resolutionStatus == .RESOLVED_UNIQUE })
    }

    @Test func contextualCaseResolvedFromEqualityWithTypedProperty() {
        #expect(edges(graph()).contains("Crossing.mayCross→Light.green"))
    }

    @Test func contextualCaseWithoutUniqueTypeIsAmbiguous() {
        var f = files
        f["Sources/Signal.swift"] = "enum Signal {\n    case green\n}"
        f["Sources/Guess.swift"] = "struct Guess {\n    func pick(_ values: [Signal]) -> Bool {\n        let v = values.first\n        return v == .green\n    }\n}"
        let g = graph(f)
        #expect(!edges(g).contains { $0.hasPrefix("Guess.pick→") && $0.hasSuffix(".green") })
        #expect(g.attempts.contains { $0.resolutionStatus == .AMBIGUOUS && $0.target == ".green" })
    }

    @Test func typedPropertyAndParameterMemberAccess() {
        let e = edges(graph())
        #expect(e.contains("Crossing.mayCross→Limits.patience"))    // property: Limits
        #expect(e.contains("Crossing.advanced→Light.next"))         // property: Light
        var f = files
        f["Sources/Judge.swift"] = "struct Judge {\n    func decide(_ c: Crossing) -> Bool {\n        return c.mayCross(3)\n    }\n}"
        #expect(edges(graph(f)).contains("Judge.decide→Crossing.mayCross"))
    }

    @Test func initializerDerivedAndAssignedTypes() {
        var f = files
        f["Sources/Plan.swift"] = """
        struct Plan {
            func run() -> Bool {
                let c = Crossing(light: .red, limits: Limits())
                let d = c
                return d.mayCross(1)
            }
        }
        """
        let e = edges(graph(f))
        #expect(e.contains("Plan.run→Crossing.mayCross"))
        #expect(e.contains("Plan.run→Crossing"))
    }

    @Test func unknownOrAmbiguousReceiverTypeCreatesNoEdge() {
        var f = files
        f["Sources/Loose.swift"] = """
        struct Loose {
            func run(_ flag: Bool) -> Bool {
                var c = Crossing(light: .red, limits: Limits())
                var c = Other()
                return c.mayCross(1)
            }
        }
        """
        f["Sources/Other.swift"] = "struct Other {\n    func mayCross(_ n: Int) -> Bool {\n        return false\n    }\n}"
        let g = graph(f)
        #expect(!edges(g).contains("Loose.run→Crossing.mayCross"))
        #expect(!edges(g).contains("Loose.run→Other.mayCross"))
    }

    @Test func sameMemberNameInUnrelatedTypeIsNotUsed() {
        var f = files
        f["Sources/Other.swift"] = "struct Other {\n    let patience = 99\n}"
        let e = edges(graph(f))
        #expect(e.contains("Crossing.mayCross→Limits.patience"))
        #expect(!e.contains("Crossing.mayCross→Other.patience"))
    }

    @Test func singleRootProofThroughEnumAndTypedMember() {
        let proof = prove("`mayCross` は light が `green` のとき、または待ち時間が 30 以上なら true を返して。", root: "Crossing.mayCross")
        #expect(proof.proven, "\(proof.obligations) \(proof.gaps) \(proof.graphReasons)")
        #expect(proof.roots.count == 1)
    }

    var board: String {
        """
        struct Board {
            let crossing: Crossing
            func show() -> Bool {
                return crossing.mayCross(0)
            }
        }
        """
    }

    @Test func twoRootProofRequiresAConnectingEdge() {
        let lean = ["Sources/Panel.swift": "struct Panel {\n    let meter: Meter\n    func render() -> Int {\n        return meter.unit.scale\n    }\n}",
                    "Sources/Meter.swift": "struct Meter {\n    let unit: Unit\n    func read() -> Int {\n        return unit.scale\n    }\n}",
                    "Sources/Unit.swift": "struct Unit {\n    let scale = 3\n}"]
        // `read` is not reachable from `render`; it joins as a second root because Meter.read → Meter.unit
        // is a resolved edge into the first component.
        let proof = prove("`render` は `read` と同じ `scale` を表示して。", root: "Panel.render", lean)
        #expect(proof.proven, "\(proof.obligations) \(proof.gaps) \(proof.graphReasons)")
        #expect(proof.roots.count == 2)
        #expect(proof.obligations.contains { $0.kind == "componentConnected" && $0.status == .resolved })
        let unrelated = prove("`patience` と `amber` を使って判定して。", root: "Limits.patience")
        #expect(!unrelated.proven)
        #expect(unrelated.obligations.contains { $0.kind == "requiredSymbolReachable" && $0.status != .resolved })
    }

    @Test func multiRootNeverWidensUnionBounds() {
        var f = files
        f["Sources/Board.swift"] = board
        let proof = prove("`show` は `advanced` と同じ信号状態を使って表示して。", root: "Board.show", f)
        #expect(!proof.proven)
        #expect(proof.gaps.contains("unionNodeBound") || proof.gaps.contains("unionEdgeBound"))
    }

    @Test func threeRootProofAndRootBound() {
        var f = files
        f["Sources/Board.swift"] = """
        struct Board {
            let crossing: Crossing
            func show() -> Bool {
                return crossing.mayCross(0)
            }
        }
        """
        let proof = prove("`show` は `Limits` と `Light` の状態を反映して。", root: "Board.show", f)
        #expect(proof.roots.count >= 2 && proof.roots.count <= 3)
        #expect(proof.proven, "\(proof.obligations) \(proof.gaps) \(proof.graphReasons)")
        let tight = prove("`show` は `Limits` と `Light` の状態を反映して。", root: "Board.show", f,
                          bounds: .init(roots: 1, depthPerRoot: 1, additionalFiles: 4, nodes: 12, edges: 16))
        #expect(!tight.proven)
        #expect(tight.gaps.contains("rootBound") || tight.gaps.contains { $0.hasPrefix("ambiguousRoot") })
    }

    @Test func multipleRootsButMissingRelationIsUnresolved() {
        var f = files
        f["Sources/Island.swift"] = "struct Island {\n    func alone() -> Int {\n        return 4\n    }\n}"
        let proof = prove("`mayCross` は `alone` の結果を使って判定して。", root: "Crossing.mayCross", f)
        #expect(!proof.proven)
        #expect(!proof.roots.contains { $0.contains("Island.alone") })
    }

    @Test func expandedGraphDoesNotResolveMissingValue() {
        let proof = prove("`mayCross` は待ち時間が 45 以上なら true を返して。", root: "Crossing.mayCross")
        #expect(!proof.proven)
        #expect(proof.obligations.contains { $0.kind == "requiredValueParticipates" && $0.detail == "45" && $0.status == .unresolved })
        #expect(proof.obligations.contains { $0.kind == "boundary" && $0.status == .unresolved })
    }

    @Test func stringsAndCommentsNeverCreateCaseEdges() {
        var f = files
        f["Sources/Text.swift"] = """
        struct Text {
            let light: Light
            func label() -> Bool {
                // light == .green
                let s = "light == .green"
                return s.isEmpty
            }
        }
        """
        #expect(!edges(graph(f)).contains("Text.label→Light.green"))
    }

    @Test func armEKeepsAdmissionPolicy() {
        let claim = VerifierAdmission.Claim(id: "C1", claimedStatus: .SATISFIED, file: "Sources/Crossing.swift", symbol: "mayCross",
                                            exactSupportingQuote: "q", rationale: "r")
        let decision = VerifierAdmission.ItemDecision(id: "C1", claimed: .SATISFIED, final: .UNCERTAIN, canonicalSymbol: "mayCross",
            passed: ["fileExists", "symbolExists", "quoteExists", "quoteInScope", "relevant"], reasons: [])
        func admit(_ text: String, receipt: Bool = true, protected: Bool = true, fresh: String = "passed") -> RequirementVerification.Verdict {
            VerifierArmE.admit(clauses: [.init(id: "C1", text: text)], requirements: [], production: files, protectedPaths: [],
                claims: [claim], phase1: [decision],
                execution: .init(receiptValid: receipt, protectedIntact: protected, freshResults: ["t()": fresh], requiredTests: ["C1": ["t()"]], notes: [])).final
        }
        let clause = "`mayCross` は light が `green` のとき、または待ち時間が 30 以上なら true を返して。"
        #expect(admit(clause) == .SATISFIED)
        #expect(admit(clause, receipt: false) == .UNCERTAIN)
        #expect(admit(clause, protected: false) == .UNCERTAIN)
        #expect(admit(clause, fresh: "failed") == .VIOLATED)
        #expect(admit("`mayCross` は待ち時間が 31 以上なら true を返して。") == .UNCERTAIN)
        #expect(admit("`mayCross` は待ち時間が 30 以上でない場合 false を返して。") == .UNCERTAIN)   // negation stays unsupported
    }
}
