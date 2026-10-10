import Foundation
import HarnessCore
import Testing
@testable import HarnessExecution

/// Synthetic, task-independent checks: READ-ONLY edit requests are routed to Target Replan,
/// behaviour-only change requirements become gaps, genuine no-change requirements do not,
/// and rollback execution truth survives later failure bookkeeping.
struct TargetRoutingTests {
    let sources: [String: String] = [
        "Sources/Kiln/Batch.swift": "struct Batch { let heat: Int }",
        "Sources/Kiln/BatchSorter.swift": "enum BatchSorter { static func order(_ items: [Batch]) -> [Batch] { items } }",
        "Sources/Kiln/Glaze.swift": "struct Glaze { let tone: String }"
    ]
    let batch = "Sources/Kiln/Batch.swift", sorter = "Sources/Kiln/BatchSorter.swift", glaze = "Sources/Kiln/Glaze.swift"
    let objective = "焼成順の並べ替えで、温度の高いものを先にして"

    func item(_ requirement: String, symbols: [String], targets: [String] = [], evidence: [String] = [],
              coverage: String = "complete", reason: String? = "") -> RequirementCoveragePlan.Item {
        .init(requirement: requirement, source_clause_ids: ["C1"], relevant_symbols: symbols, editable_targets: targets,
              read_only_evidence: evidence, rationale: "r", coverage: coverage, no_change_reason: reason)
    }
    func assess(_ items: [RequirementCoveragePlan.Item], editable: Set<String>, readOnly: Set<String>) -> [TargetCoverage.Entry] {
        TargetCoverage.assess(.init(requirements: items), objective: objective, editable: editable, readOnly: readOnly, sources: sources)
    }

    @Test func readOnlyEditRequestIsRoutedNotCovered() {
        // An editable file declares the shared type, but the plan asks to edit the READ-ONLY user of it.
        let entries = assess([item("Sort batches by heat in BatchSorter.order", symbols: ["Batch", "BatchSorter", "order"],
                                   targets: [sorter])], editable: [batch], readOnly: [sorter])
        #expect(entries[0].coverageState == .TARGET_COVERAGE_GAP && entries[0].blocking)
        #expect(entries[0].readOnlyEvidence == [sorter])
        #expect(entries[0].reason.contains("edit requested for READ-ONLY"))
        // The ordinary plan status still asks for escalation: nothing was promoted by the request itself.
        let status = RequirementCoverage.assess(.init(requirements: [item("x", symbols: ["BatchSorter"], targets: [sorter])]),
            editable: [batch], readOnly: [sorter], sources: sources).status
        #expect(status == .planRequestsEscalation)
    }

    @Test func routedRequestPromotesOnlyWithValidRelation() {
        let entries = assess([item("Sort batches by heat in BatchSorter.order", symbols: ["Batch", "BatchSorter", "order"],
                                   targets: [sorter])], editable: [batch], readOnly: [sorter, glaze])
        let gaps = TargetCoverage.blockingGaps(entries)
        func verify(_ file: String, _ symbol: String) -> TargetCoverage.Verdict {
            TargetCoverage.verify(.init(requirement_id: "R1", file: file, symbol: symbol, relation: "uses", why_edit: "sort"),
                gaps: gaps, objective: objective, editable: [batch], sources: sources, tests: [:], protected: [])
        }
        let valid = verify(sorter, "order")
        #expect(valid.accepted)
        #expect(valid.evidence.contains { $0.hasPrefix("dependency: references Batch declared by editable") })
        #expect(!valid.evidence.contains { $0.hasPrefix("test:") })
        let unrelated = verify(glaze, "Glaze")
        #expect(!unrelated.accepted && unrelated.rejection == "notRelatedToRequirement")
    }

    @Test func behaviourOnlyRequirementWithoutConcreteReasonIsGap() {
        let reasons: [String?] = [nil, "", "The file Sources/Kiln/BatchSorter.swift is read-only and no editable files are provided.",
                                  "BatchSorter.swift is not editable", "並べ替えは読み取り専用のため変更できない"]
        for reason in reasons {
            let entries = assess([item("Order batches so hotter ones come first", symbols: ["BatchSorter", "order"],
                                       reason: reason)], editable: [], readOnly: [batch, sorter])
            #expect(entries[0].coverageState == .TARGET_COVERAGE_GAP && entries[0].blocking, "reason: \(reason ?? "nil")")
            #expect(entries[0].readOnlyEvidence == [sorter])
        }
        // A plan that is itself unsure is not a no-change claim either.
        let unsure = assess([item("Order batches", symbols: ["BatchSorter"], coverage: "uncertain",
                                  reason: "Existing ordering already satisfies this.")], editable: [], readOnly: [sorter])
        #expect(unsure[0].coverageState == .TARGET_COVERAGE_GAP)
    }

    @Test func genuineNoChangeRequirementStaysNoChange() {
        let entries = assess([
            item("Keep the Glaze tone format unchanged", symbols: ["Glaze", "tone"],
                 reason: "The objective asks to keep the tone format as it is; existing behaviour already matches."),
            item("Do not change the Batch public API", symbols: ["Batch"],
                 reason: "Only ordering changes; the heat property keeps its current type and meaning.")
        ], editable: [], readOnly: [batch, glaze])
        #expect(entries.map(\.coverageState) == [.NO_CHANGE_REQUIRED, .NO_CHANGE_REQUIRED])
        #expect(TargetCoverage.blockingGaps(entries).isEmpty)
    }

    @Test func behaviourOnlyWithEditableOwnerIsCoveredNotGap() {
        let entries = assess([item("Order batches so hotter ones come first", symbols: ["BatchSorter", "order"], reason: "")],
                             editable: [sorter], readOnly: [batch])
        #expect(entries[0].coverageState == .COVERED && !entries[0].blocking)
    }

    @Test func newSymbolCoverageUnchanged() {
        let entries = assess([item("Add isHot to Batch", symbols: ["Batch", "isHot"], targets: [batch])],
                             editable: [batch], readOnly: [sorter])
        #expect(entries[0].coverageState == .COVERED)
    }

    @Test func noFalseEditablePromotionAcrossRoutedGaps() {
        // Only verified nominations may be promoted; at most maximumPromotions, never all READ-ONLY evidence.
        let entries = assess([
            item("Sort in BatchSorter", symbols: ["BatchSorter", "order"], targets: [sorter]),
            item("Recolour glaze", symbols: ["Glaze"], reason: "")
        ], editable: [batch], readOnly: [sorter, glaze])
        let gaps = TargetCoverage.blockingGaps(entries)
        let verdicts = [(sorter, "order"), (glaze, "Glaze"), ("Sources/Kiln/Missing.swift", "X")].map {
            TargetCoverage.verify(.init(requirement_id: "R1", file: $0.0, symbol: $0.1, relation: "", why_edit: "x"),
                gaps: gaps, objective: objective, editable: [batch], sources: sources, tests: [:], protected: [])
        }
        let promoted = verdicts.filter(\.accepted).map(\.file)
        #expect(promoted == [sorter])
        #expect(TargetCoverage.maximumPromotions == 2)
    }

    @Test func rollbackTruthSurvivesLaterFailure() {
        var outcome = RollbackOutcome.merge(nil, .NOT_ATTEMPTED)
        outcome = RollbackOutcome.merge(outcome, RollbackOutcome(detail: "PASS"))
        #expect(outcome == .ATTEMPTED_SUCCESS)
        outcome = RollbackOutcome.merge(outcome, RollbackOutcome(detail: "NOT_NEEDED"))   // later fail() default
        #expect(outcome == .ATTEMPTED_SUCCESS)
        #expect(RollbackOutcome.merge(.ATTEMPTED_FAIL, RollbackOutcome(detail: "PASS")) == .ATTEMPTED_FAIL)
        #expect(RollbackOutcome.merge(.NOT_ATTEMPTED, RollbackOutcome(detail: "NOT_NEEDED")) == .NOT_NEEDED)
        for detail in ["FAILED", "INCOMPLETE", "REPAIR_ROLLBACK_FAILED"] {
            #expect(RollbackOutcome(detail: detail) == .ATTEMPTED_FAIL)
        }
    }
}
