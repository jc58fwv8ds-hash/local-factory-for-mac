import Foundation
import HarnessCore
import Testing
@testable import HarnessExecution

/// Synthetic objectives unrelated to any D2 fixture: structural segmentation and the
/// Clause Coverage Gate.
struct ObjectiveClauseTests {
    typealias Item = RequirementCoveragePlan.Item
    let sources = ["Sources/Box/Shelf.swift": "struct Shelf {}", "Sources/Box/Label.swift": "struct Label {}"]
    func item(_ req: String, _ ids: [String], targets: [String] = ["Sources/Box/Shelf.swift"], reason: String? = nil) -> Item {
        .init(requirement: req, source_clause_ids: ids, relevant_symbols: [], editable_targets: targets,
              read_only_evidence: [], rationale: "r", coverage: "complete", no_change_reason: reason)
    }
    func texts(_ objective: String) -> [String] { ObjectiveClauses.segment(objective).map(\.exactSourceText) }

    @Test func twoPlainSentencesBecomeTwoMandatoryClauses() {
        let clauses = ObjectiveClauses.segment("棚に本を追加して。ラベルを表示して。")
        #expect(clauses.map(\.exactSourceText) == ["棚に本を追加して", "ラベルを表示して"])
        #expect(clauses.allSatisfy(\.mandatoryCandidate) && clauses.map(\.clauseID) == ["C1", "C2"])
    }

    @Test func parentheticalIsKeptAsItsOwnMandatoryClause() {
        let clauses = ObjectiveClauses.segment("棚の名前を保存して（名前が空なら既定名にする）。")
        let paren = clauses.first { $0.clauseType == .parenthetical }
        #expect(paren?.exactSourceText == "名前が空なら既定名にする" && paren?.mandatoryCandidate == true)
        #expect(paren?.features.contains("conditional") == true)
        // The enclosing sentence is preserved too; nothing is dropped as a remark.
        #expect(clauses.contains { $0.exactSourceText.hasPrefix("棚の名前を保存して") })
        let english = ObjectiveClauses.segment("Store the shelf name (use the default when it is empty).")
        #expect(english.contains { $0.clauseType == .parenthetical && $0.exactSourceText == "use the default when it is empty" })
    }

    @Test func negationNumericAndConditionalSubclausesAreDetected() {
        let negation = ObjectiveClauses.segment("既存の保存形式は変えないで。")[0]
        #expect(negation.clauseType == .negation && negation.mandatoryCandidate)
        let numeric = ObjectiveClauses.segment("ラベルは 40 文字以下にして。")[0]
        #expect(numeric.features.contains("numericConstraint"))
        let limit = ObjectiveClauses.segment("Reject names longer than 64 characters.")[0]
        #expect(limit.features.contains("numericConstraint"))
        let clauses = ObjectiveClauses.segment("棚が満杯の場合は追加を拒否し、それ以外は末尾に追加して。")
        #expect(clauses.contains { $0.clauseType == .conditional && $0.exactSourceText == "棚が満杯の場合は追加を拒否し" })
    }

    @Test func optionalExplanationIsNotMandatory() {
        let clauses = ObjectiveClauses.segment("最近は本が増えてきた。棚に本を追加して。")
        #expect(clauses[0].clauseType == .explanatory && !clauses[0].mandatoryCandidate)
        #expect(clauses[1].mandatoryCandidate)
    }

    @Test func decimalsAndFileNamesDoNotSplitSentences() {
        #expect(texts("Package.swift の値を 1.5 倍にして。") == ["Package.swift の値を 1.5 倍にして"])
    }

    @Test func codeSyntaxParenthesesAreNotProseClauses() {
        let clauses = ObjectiveClauses.segment("Shelf に count(of:) を追加して、戻り値 (Int?) を返して（空なら nil）。")
        let parens = clauses.filter { $0.clauseType == .parenthetical }.map(\.exactSourceText)
        #expect(parens == ["空なら nil"])
    }

    @Test func thousandSeparatorsDoNotSplitClauses() {
        let clauses = ObjectiveClauses.segment("上限 1,000,000 件を超えたら拒否し、それ以外は保存して。")
        #expect(!clauses.contains { $0.exactSourceText.hasSuffix("1") || $0.exactSourceText.hasPrefix("000") })
        #expect(clauses.contains { $0.clauseType == .conditional && $0.exactSourceText == "上限 1,000,000 件を超えたら拒否し" })
    }

    @Test func clauseIDsAreDeterministic() {
        let objective = "棚に本を追加して（重複なら拒否）。ラベルは 40 文字以下にして。"
        let runs = (0..<5).map { _ in ObjectiveClauses.segment(objective) }
        #expect(Set(runs.map { $0.map(\.clauseID) + $0.map(\.exactSourceText) }).count == 1)
        #expect(runs[0].map(\.sourceRange).allSatisfy { $0.count == 2 && $0[1] > 0 })
    }

    @Test func oneClauseManyRequirementsAndManyClausesOneRequirement() {
        let clauses = ObjectiveClauses.segment("棚に本を追加して。ラベルを表示して。")
        let split = RequirementCoveragePlan(requirements: [item("add storage", ["C1"]), item("add call site", ["C1"]),
                                                           item("show label", ["C2"], targets: ["Sources/Box/Label.swift"])])
        #expect(RequirementCoverage.clauseCoverage(split, clauses: clauses, sources: sources).complete)
        let merged = RequirementCoveragePlan(requirements: [item("add and show", ["C1", "C2"])])
        #expect(RequirementCoverage.clauseCoverage(merged, clauses: clauses, sources: sources).complete)
    }

    @Test func uncoveredParentheticalIsDetectedDespiteCompleteSelfReport() {
        let clauses = ObjectiveClauses.segment("棚の名前を保存して（名前が空なら既定名にする）。")
        let parenID = clauses.first { $0.clauseType == .parenthetical }!.clauseID
        let sentenceID = clauses.first { $0.clauseType != .parenthetical }!.clauseID
        // The model cites only the enclosing sentence and labels everything "complete".
        let plan = RequirementCoveragePlan(requirements: [item("save the name", [sentenceID])])
        let coverage = RequirementCoverage.clauseCoverage(plan, clauses: clauses, sources: sources)
        #expect(!coverage.complete && coverage.uncovered == [parenID])
        let feedback = RequirementCoverage.clauseReplanFeedback(coverage, clauses: clauses)
        #expect(feedback.contains(parenID) && feedback.contains("名前が空なら既定名にする"))
        // After replan the clause is cited: coverage completes.
        let replanned = RequirementCoveragePlan(requirements: [item("save the name", [sentenceID]),
                                                               item("default when empty", [parenID])])
        #expect(RequirementCoverage.clauseCoverage(replanned, clauses: clauses, sources: sources).complete)
    }

    @Test func ungroundedOrUnknownCitationsDoNotCover() {
        let clauses = ObjectiveClauses.segment("棚に本を追加して。既存の保存形式は変えないで。")
        let noChange = RequirementCoveragePlan(requirements: [item("add", ["C1"]),
            item("keep format", ["C2"], targets: [], reason: "only a computed property is added")])
        #expect(RequirementCoverage.clauseCoverage(noChange, clauses: clauses, sources: sources).complete)
        let ungrounded = RequirementCoveragePlan(requirements: [item("add", ["C1"]), item("keep format", ["C2", "C9"], targets: [])])
        let c = RequirementCoverage.clauseCoverage(ungrounded, clauses: clauses, sources: sources)
        #expect(c.uncovered == ["C2"] && c.unknownCitations == ["C9"])
    }

    @Test func preservationRequirementNeedsReasonAndGetsActionableFeedback() {
        let clauses = ObjectiveClauses.segment("棚に本を追加して。既存の保存形式は変えないで。")
        let missingReason = RequirementCoveragePlan(requirements: [item("add", ["C1"]), item("keep format", ["C2"], targets: [])])
        let a = RequirementCoverage.assess(missingReason, editable: ["Sources/Box/Shelf.swift"], readOnly: [], sources: sources)
        #expect(a.status == .incomplete && a.uncovered == ["keep format"])
        let feedback = RequirementCoverage.incompleteFeedback(a)
        #expect(feedback.contains("keep format") && feedback.contains("no_change_reason"))
        let fixed = RequirementCoveragePlan(requirements: [item("add", ["C1"]),
            item("keep format", ["C2"], targets: [], reason: "only a new method is added")])
        #expect(RequirementCoverage.assess(fixed, editable: ["Sources/Box/Shelf.swift"], readOnly: [], sources: sources).status == .ready)
        #expect(RequirementCoverage.clauseCoverage(fixed, clauses: clauses, sources: sources).complete)
    }

    @Test func noChangeReasonIsRequiredBySchema() throws {
        let request = InferenceRequest(runtime: .ollama, modelIdentifier: "m", messages: [.init(role: .user, content: "x")],
            structuredOutput: .coveragePlan)
        let body = try JSONSerialization.jsonObject(with: InferencePayloadEncoder.body(for: request)) as! [String: Any]
        let item = ((((body["format"] as! [String: Any])["properties"] as! [String: Any])["requirements"] as! [String: Any])["items"]) as! [String: Any]
        #expect((item["required"] as! [String]).contains("no_change_reason"))
        #expect((item["required"] as! [String]).contains("source_clause_ids"))
    }

    @Test func clauseReplanIsBoundedThenFails() {
        var budget = RequirementCoverage.Budget()
        let first = budget.consume(.clauseReplan)
        let second = budget.consume(.clauseReplan) // still uncovered after replan → FAIL, no more replans
        #expect(first && !second)
    }
}
