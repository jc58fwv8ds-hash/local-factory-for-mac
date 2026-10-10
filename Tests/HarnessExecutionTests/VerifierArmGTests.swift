import Foundation
import Testing
@testable import HarnessExecution

/// Synthetic, task-independent checks of Phase 6 (Arm G): behavioural relations must be proven from the
/// parsed condition structure; presence and participation alone never admit a behavioural clause.
struct VerifierArmGTests {
    typealias G = VerifierSemanticObligationsG

    func heater(_ condition: String, extra: String = "") -> [String: String] {
        ["Sources/Heater.swift": """
        struct Heater {
            let armed: Bool
            let override: Bool
            func shouldHeat(_ temp: Int) -> Bool {
        \(extra)
                if \(condition) { return true }
                return false
            }
        }
        """]
    }

    func admit(_ clause: String, _ files: [String: String], arm: String = "G", receipt: Bool = true) -> (RequirementVerification.Verdict, VerifierArmG.ItemDecision?) {
        let claim = VerifierAdmission.Claim(id: "C1", claimedStatus: .SATISFIED, file: "Sources/Heater.swift", symbol: "shouldHeat", exactSupportingQuote: "q", rationale: "r")
        let decision = VerifierAdmission.ItemDecision(id: "C1", claimed: .SATISFIED, final: .UNCERTAIN, canonicalSymbol: "shouldHeat",
            passed: ["fileExists", "symbolExists", "quoteExists", "quoteInScope", "relevant"], reasons: [])
        let execution = VerifierArmD.Execution(receiptValid: receipt, protectedIntact: true, freshResults: ["t()": "passed"], requiredTests: ["C1": ["t()"]], notes: [])
        let items: [RequirementVerification.Item] = [.init(id: "C1", text: clause)]
        if arm == "F" {
            return (VerifierArmF.admit(clauses: items, requirements: [], production: files, protectedPaths: [], claims: [claim], phase1: [decision], execution: execution).final, nil)
        }
        let g = VerifierArmG.admit(clauses: items, requirements: [], production: files, protectedPaths: [], claims: [claim], phase1: [decision], execution: execution)
        return (g.final, g.items.first)
    }
    func status(_ item: VerifierArmG.ItemDecision?, _ type: G.RelationType) -> G.Status? {
        item?.semantic?.obligations.first { $0.relationType == type }?.resolutionStatus
    }

    let andClause = "`shouldHeat` は `armed` かつ温度が 15 未満のとき true を返して。"

    @Test func andRequirementWithAndImplementationIsProven() {
        let (verdict, item) = admit(andClause, heater("armed && temp < 15"))
        #expect(verdict == .SATISFIED, "\(String(describing: item?.reasons)) \(String(describing: item?.semantic))")
        #expect(item?.semantic?.strength == .RELATION_PROVEN)
        let conj = item?.semantic?.obligations.first { $0.relationType == .conjunction }
        #expect(conj?.resolutionStatus == .RELATION_PROVEN && conj?.operatorEvidence == "&&" && conj?.sourceRange != nil)
    }

    @Test func andRequirementWithOrImplementationIsNotAdmitted() {
        #expect(admit(andClause, heater("armed || temp < 15"), arm: "F").0 == .SATISFIED)   // presence proof alone (Arm F) admits it
        let (verdict, item) = admit(andClause, heater("armed || temp < 15"))
        #expect(verdict == .UNCERTAIN)
        #expect(status(item, .conjunction) == .RELATION_UNPROVEN)
    }

    @Test func orRequirementChecksDisjunction() {
        let clause = "`shouldHeat` は `armed` または温度が 15 未満のとき true を返して。"
        #expect(admit(clause, heater("armed || temp < 15")).0 == .SATISFIED)
        let (verdict, item) = admit(clause, heater("armed && temp < 15"))
        #expect(verdict == .UNCERTAIN && status(item, .disjunction) == .RELATION_UNPROVEN)
    }

    @Test func nestedGroupingIsStructural() {
        #expect(admit(andClause, heater("armed && (temp < 15)")).0 == .SATISFIED)
        let (verdict, item) = admit(andClause, heater("(armed && temp < 15) || override"))
        #expect(verdict == .UNCERTAIN)
        #expect(status(item, .conjunction) == .RELATION_UNPROVEN)
    }

    @Test func comparisonOperatorMustMatchExactly() {
        let clause = "`shouldHeat` は温度が 15 未満なら true を返して。"
        #expect(admit(clause, heater("temp < 15")).0 == .SATISFIED)
        #expect(admit(clause, heater("15 > temp")).0 == .SATISFIED)                          // mirrored form
        let (verdict, item) = admit(clause, heater("!(temp >= 15)"))
        #expect(verdict == .UNCERTAIN && status(item, .comparison) == .RELATION_UNPROVEN)
    }

    @Test func onlyWhenPresenceOnlyIsUncertainAndGuardedFormIsProven() {
        let clause = "`shouldHeat` は `armed` のときだけ true を返して。"
        let (verdict, item) = admit(clause, heater("armed || override"))
        #expect(verdict == .UNCERTAIN && status(item, .exclusivity) == .EXCLUSIVITY_UNPROVEN)
        let (proven, provenItem) = admit(clause, heater("armed && override"))
        #expect(status(provenItem, .exclusivity) == .RELATION_PROVEN, "\(String(describing: provenItem?.semantic))")
        #expect(proven == .SATISFIED)
    }

    @Test func regardlessOfAndOtherwiseUnchangedStayUnproven() {
        let regardless = admit("`shouldHeat` は `override` に関係なく、`armed` なら true を返して。", heater("armed"))
        #expect(regardless.0 == .UNCERTAIN && status(regardless.1, .independence) == .INDEPENDENCE_UNPROVEN)
        let preserved = admit("`shouldHeat` は `armed` なら true を返し、それ以外は今までどおりにして。", heater("armed"))
        #expect(preserved.0 == .UNCERTAIN && status(preserved.1, .preservation) == .PRESERVATION_UNPROVEN)
    }

    @Test func unclassifiableBehaviourIsUnsupported() {
        let (verdict, item) = admit("`shouldHeat` の結果には `armed` の状態を反映して。", heater("armed"))
        #expect(verdict == .UNCERTAIN)
        #expect(status(item, .unsupported) == .UNSUPPORTED_SEMANTIC_OBLIGATION)
    }

    @Test func pureDeclarationClauseNeedsNoRelation() {
        let (verdict, item) = admit("`Heater` に `armed` プロパティを追加して。", heater("armed"))
        #expect(item?.semantic?.presenceOnlyClause == true)
        #expect(verdict == .SATISFIED || item?.layer != "semantic")
    }

    @Test func provenRelationStillNeedsValidReceipt() {
        #expect(admit(andClause, heater("armed && temp < 15"), receipt: true).0 == .SATISFIED)
        #expect(admit(andClause, heater("armed && temp < 15"), receipt: false).0 == .UNCERTAIN)
    }

    @Test func offPathUnresolvedReferenceDoesNotBlockProvenRelation() {
        let extra = "        let probe = make()\n        let noted = probe.armed"
        let (verdict, item) = admit(andClause, heater("armed && temp < 15", extra: extra))
        #expect(verdict == .SATISFIED, "\(String(describing: item?.reasons))")
    }

    @Test func conditionParserBuildsTrees() {
        let tokens = try! VerifierSourceTokens.scan("a && (b || !c) && d >= 3")
        guard case .and(let kids)? = VerifierConditionStructure.parse(tokens) else { Issue.record("not an AND tree"); return }
        #expect(kids.count == 3)
        if case .or(let inner) = kids[1] { #expect(inner.count == 2) } else { Issue.record("grouping lost") }
        if case .atom(let a) = kids[2] { #expect(a.op == ">=" && a.rhs == "3") } else { Issue.record("comparison lost") }
        #expect(VerifierConditionStructure.parse(try! VerifierSourceTokens.scan("a && (b")) == nil)
    }

    @Test func operatorMustBelongToTheSiteProducingTheResult() {
        let files = ["Sources/Heater.swift": """
        enum Mode {
            case boost, idle
        }
        struct Heater {
            let armed: Bool
            let override: Bool
            func mode(_ temp: Int) -> Mode {
                if armed && override { return .idle }
                if armed || override { return .boost }
                return .idle
            }
        }
        """]
        let claim = VerifierAdmission.Claim(id: "C1", claimedStatus: .SATISFIED, file: "Sources/Heater.swift", symbol: "mode", exactSupportingQuote: "q", rationale: "r")
        let decision = VerifierAdmission.ItemDecision(id: "C1", claimed: .SATISFIED, final: .UNCERTAIN, canonicalSymbol: "mode",
            passed: ["fileExists", "symbolExists", "quoteExists", "quoteInScope", "relevant"], reasons: [])
        let g = VerifierArmG.admit(clauses: [.init(id: "C1", text: "`mode` は `armed` かつ `override` のとき `.boost` を返して。")], requirements: [],
            production: files, protectedPaths: [], claims: [claim], phase1: [decision],
            execution: .init(receiptValid: true, protectedIntact: true, freshResults: ["t()": "passed"], requiredTests: ["C1": ["t()"]], notes: []))
        #expect(g.final != .SATISFIED)
        #expect(g.items.first?.semantic?.obligations.first { $0.relationType == .conjunction }?.resolutionStatus != .RELATION_PROVEN)
    }
}
