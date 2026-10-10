import Foundation
import HarnessCore
import Testing
@testable import HarnessExecution

/// Synthetic checks of plan 0005 F1–F2 (selector-form symbols, promotion limit). F3 was withdrawn: see the plan.
struct TargetReplanCoverageFixTests {
    func item(_ requirement: String, symbols: [String], targets: [String] = [], evidence: [String] = []) -> RequirementCoveragePlan.Item {
        .init(requirement: requirement, source_clause_ids: ["C1"], relevant_symbols: symbols, editable_targets: targets,
              read_only_evidence: evidence, rationale: "r", coverage: "complete", no_change_reason: "")
    }
    func nominate(_ file: String, _ symbol: String, requirement: String = "R1") -> TargetNomination.Item {
        .init(requirement_id: requirement, file: file, symbol: symbol, relation: "owns the rule", why_edit: "apply the request")
    }

    @Test func selectorFormSymbolsMatchTheirBaseName() {
        #expect(TargetCoverage.baseName("render(_:)") == "render")
        #expect(TargetCoverage.baseName("init?(code:)") == "init")
        #expect(TargetCoverage.baseName("LoanPolicy.of(_:)") == "of")
        #expect(TargetCoverage.baseName(" tierLabel ") == "tierLabel")
        let sources = ["Sources/Lib/Member.swift": "struct Member { let tier: Tier }",
                       "Sources/Lib/Notices.swift": "enum Notices { static func tierLabel(_ tier: Tier) -> String { \"\" } }",
                       "Sources/Lib/Tier.swift": "enum Tier { case basic }"]
        let plan = RequirementCoveragePlan(requirements: [item("Show the new tier in tierLabel", symbols: ["tierLabel", "Tier"],
                                                               targets: ["Sources/Lib/Notices.swift"])])
        let gaps = TargetCoverage.blockingGaps(TargetCoverage.assess(plan, objective: "Tier に premium を追加して表示も", editable: ["Sources/Lib/Tier.swift"],
                                                                     readOnly: ["Sources/Lib/Notices.swift"], sources: sources))
        #expect(gaps.map(\.requirementID) == ["R1"])
        func verify(_ symbol: String) -> TargetCoverage.Verdict {
            TargetCoverage.verify(nominate("Sources/Lib/Notices.swift", symbol), gaps: gaps, objective: "Tier に premium を追加して表示も",
                                  editable: ["Sources/Lib/Tier.swift"], sources: sources, tests: [:], protected: [])
        }
        #expect(verify("tierLabel(_:)").accepted)
        #expect(verify("Notices.tierLabel(_:)").accepted)
        #expect(verify("missingLabel(_:)").rejection == "symbolNotFound")   // normalisation adds no acceptance path
    }

    @Test func promotionLimitFollowsTheNumberOfGapsWithinBounds() {
        let sources = (1...5).reduce(into: ["Sources/A/Core.swift": "struct Core { let base: Int }"]) {
            $0["Sources/A/Part\($1).swift"] = "struct Part\($1) { func ruleNumber\($1)() -> Int { 0 } }"
        }
        func limit(_ count: Int) -> Int {
            let items = (1...count).map { item("Change ruleNumber\($0)", symbols: ["ruleNumber\($0)"], targets: ["Sources/A/Part\($0).swift"]) }
            let gaps = TargetCoverage.blockingGaps(TargetCoverage.assess(.init(requirements: items), objective: "ルールを変えて",
                editable: ["Sources/A/Core.swift"], readOnly: Set((1...count).map { "Sources/A/Part\($0).swift" }), sources: sources))
            #expect(gaps.count == count)
            return TargetCoverage.promotionLimit(gaps: gaps)
        }
        #expect(limit(1) == 2)
        #expect(limit(3) == 3)
        #expect(limit(5) == TargetNomination.maximumItems)
    }
}
