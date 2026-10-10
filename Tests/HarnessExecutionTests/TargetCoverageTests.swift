import Foundation
import HarnessCore
import Testing
@testable import HarnessExecution

/// Synthetic, task-independent checks of the per-requirement Editable Owner assessment,
/// Target Replan nomination verification and the plan patch.
struct TargetCoverageTests {
    let sources: [String: String] = [
        "Sources/Garden/Plant.swift": "struct Plant { let species: String; var height: Int }",
        "Sources/Garden/Planter.swift": "struct Planter { func tallest(_ plants: [Plant]) -> Plant? { let waterLevel = 1; return plants.max { $0.height < $1.height } } }",
        "Sources/Garden/Weather.swift": "struct Weather { let celsius: Int }",
        "Sources/Garden/Sprinkler.swift": "enum Sprinkler { static func limit() -> Int { 125_000 } }"
    ]
    let tests = ["Tests/GardenTests/PlantAcceptance.swift": "let p = Plant(species: \"a\", height: 3); _ = p.isFlowering"]
    let objective = "Plant に isFlowering を追加して、Planter の選択でも使って"

    func item(_ requirement: String, symbols: [String], targets: [String] = [], evidence: [String] = [],
              reason: String? = "") -> RequirementCoveragePlan.Item {
        .init(requirement: requirement, source_clause_ids: ["C1"], relevant_symbols: symbols, editable_targets: targets,
              read_only_evidence: evidence, rationale: "r", coverage: "complete", no_change_reason: reason)
    }
    func assess(_ items: [RequirementCoveragePlan.Item], editable: Set<String>, readOnly: Set<String>) -> [TargetCoverage.Entry] {
        TargetCoverage.assess(.init(requirements: items), objective: objective, editable: editable, readOnly: readOnly, sources: sources)
    }
    func nominate(_ file: String, _ symbol: String = "", requirement: String = "R1") -> TargetNomination.Item {
        .init(requirement_id: requirement, file: file, symbol: symbol, relation: "owns the type", why_edit: "add member")
    }

    @Test func newSymbolWithoutEditableOwnerIsABlockingGapWithEvidence() {
        let entries = assess([item("Add isFlowering to Plant", symbols: ["Plant", "isFlowering"],
                                   evidence: ["Sources/Garden/Plant.swift"], reason: "Plant is read-only")],
                             editable: ["Sources/Garden/Planter.swift"], readOnly: ["Sources/Garden/Plant.swift"])
        let e = entries[0]
        #expect(e.requirementID == "R1" && e.coverageState == .TARGET_COVERAGE_GAP && e.blocking)
        #expect(e.editableOwners.isEmpty && e.readOnlyEvidence == ["Sources/Garden/Plant.swift"])
        #expect(e.newSymbols == ["isFlowering"] && !e.reason.isEmpty)
    }

    @Test func coveredNoChangeAndNonBlockingStates() {
        let entries = assess([
            item("Use isFlowering in tallest", symbols: ["Planter", "tallest", "isFlowering"], targets: ["Sources/Garden/Planter.swift"]),
            item("Keep the Weather API unchanged", symbols: ["Weather"], reason: "no change needed"),
            item("Add bloomColor", symbols: ["bloomColor"])
        ], editable: ["Sources/Garden/Planter.swift"], readOnly: ["Sources/Garden/Plant.swift"])
        #expect(entries.map(\.coverageState) == [.COVERED, .NO_CHANGE_REQUIRED, .TARGET_COVERAGE_GAP])
        #expect(entries[0].editableOwners == ["Sources/Garden/Planter.swift"])
        #expect(entries[1].reason == "no change needed")
        // No directly related read-only evidence: recorded, but not blocking.
        #expect(!entries[2].blocking && TargetCoverage.blockingGaps(entries).isEmpty)
    }

    @Test func objectiveMemberMissingFromNamedTypeIsNewEvenIfNameExistsElsewhere() {
        // "waterLevel" exists as a local elsewhere but is not declared by the named type's file.
        let entries = TargetCoverage.assess(.init(requirements: [item("Add waterLevel to Plant", symbols: ["Plant", "waterLevel"])]),
            objective: "Plant に waterLevel を追加して", editable: ["Sources/Garden/Planter.swift"],
            readOnly: ["Sources/Garden/Plant.swift"], sources: sources)
        #expect(entries[0].newSymbols == ["waterLevel"] && entries[0].blocking)
        #expect(entries[0].editableOwners.isEmpty)
    }

    @Test func nominationNeedsRequirementAndTaskEvidence() {
        let entries = assess([item("Add isFlowering to Plant", symbols: ["Plant", "isFlowering"])],
                             editable: ["Sources/Garden/Planter.swift"], readOnly: ["Sources/Garden/Plant.swift", "Sources/Garden/Weather.swift"])
        let gaps = TargetCoverage.blockingGaps(entries)
        func verify(_ n: TargetNomination.Item, tests: [String: String] = [:], protected: Set<String> = []) -> TargetCoverage.Verdict {
            TargetCoverage.verify(n, gaps: gaps, objective: objective, editable: ["Sources/Garden/Planter.swift"],
                                  sources: sources, tests: tests, protected: protected)
        }
        let ok = verify(nominate("Sources/Garden/Plant.swift", "Plant"))
        #expect(ok.accepted && ok.evidence.contains("definition: declares Plant"))
        #expect(ok.evidence.contains { $0.hasPrefix("dependency: declares Plant referenced by editable") })
        #expect(verify(nominate("Sources/Garden/Plant.swift", "isFlowering")).accepted)
        #expect(verify(nominate("Sources/Garden/Missing.swift")).rejection == "fileNotFound")
        #expect(verify(nominate("Sources/Garden/Plant.swift", "Nonexistent")).rejection == "symbolNotFound")
        #expect(verify(nominate("Sources/Garden/Plant.swift", "Weather")).rejection == "symbolNotInFile")
        #expect(verify(nominate("Sources/Garden/Weather.swift")).rejection == "notRelatedToRequirement")
        #expect(verify(nominate("Sources/Garden/Planter.swift")).rejection == "alreadyEditable")
        #expect(verify(nominate("Sources/Garden/Plant.swift"), protected: ["Sources/Garden/Plant.swift"]).rejection == "protectedOrTest")
        #expect(verify(nominate("../Plant.swift")).rejection == "invalidPath")
        #expect(verify(nominate("Sources/Garden/Plant.swift", requirement: "R9")).accepted) // falls back to the related gap
    }

    @Test func requirementAnchorAloneIsInsufficient() {
        // No editable targets, no objective declaration, no test reference: definition only.
        let entries = TargetCoverage.assess(.init(requirements: [item("Add isFlowering to Plant", symbols: ["Plant", "isFlowering"])]),
            objective: "花の状態を返すプロパティを追加", editable: [], readOnly: ["Sources/Garden/Plant.swift"], sources: sources)
        let gaps = TargetCoverage.blockingGaps(entries)
        let rejected = TargetCoverage.verify(nominate("Sources/Garden/Plant.swift", "Plant"), gaps: gaps,
            objective: "花の状態を返すプロパティを追加", editable: [], sources: sources, tests: [:], protected: [])
        #expect(rejected.rejection == "insufficientEvidence")
        let withTest = TargetCoverage.verify(nominate("Sources/Garden/Plant.swift", "Plant"), gaps: gaps,
            objective: "花の状態を返すプロパティを追加", editable: [], sources: sources, tests: tests, protected: [])
        #expect(withTest.accepted && withTest.evidence.contains { $0.hasPrefix("test: ") })
    }

    @Test func patchOnlyRewritesResolvedGaps() {
        let plan = RequirementCoveragePlan(requirements: [
            item("Add isFlowering to Plant", symbols: ["Plant", "isFlowering"], evidence: ["Sources/Garden/Plant.swift"], reason: "read-only"),
            item("Keep Weather", symbols: ["Weather"], reason: "unchanged")
        ])
        let before = TargetCoverage.assess(plan, objective: objective, editable: [], readOnly: ["Sources/Garden/Plant.swift"], sources: sources)
        let after = TargetCoverage.assess(plan, objective: objective, editable: ["Sources/Garden/Plant.swift"], readOnly: [], sources: sources)
        #expect(before[0].blocking && after[0].coverageState == .COVERED)
        let patched = TargetCoverage.patch(plan, before: before, after: after)
        #expect(patched.requirements[0].editable_targets == ["Sources/Garden/Plant.swift"])
        #expect(patched.requirements[0].read_only_evidence.isEmpty && patched.requirements[0].no_change_reason == "")
        #expect(patched.requirements[1] == plan.requirements[1])
    }

    @Test func promptCarriesOnlyGapContextAndBudgetIsSingleUse() throws {
        let entries = assess([item("Add isFlowering to Plant", symbols: ["Plant", "isFlowering"])],
                             editable: ["Sources/Garden/Planter.swift"], readOnly: ["Sources/Garden/Plant.swift"])
        let prompt = try TargetCoverage.nominationPrompt(objective: objective, gaps: TargetCoverage.blockingGaps(entries),
            editable: ["Sources/Garden/Planter.swift": sources["Sources/Garden/Planter.swift"]!],
            evidence: ["Sources/Garden/Plant.swift": sources["Sources/Garden/Plant.swift"]!])
        #expect(prompt.contains("R1") && prompt.contains("Sources/Garden/Plant.swift"))
        #expect(!prompt.contains("PlantAcceptance") && !prompt.contains("Weather"))
        var budget = RequirementCoverage.Budget()
        let first = budget.consume(.targetReplan)
        let second = budget.consume(.targetReplan)
        #expect(first && !second)
    }

    @Test func nominationSchemaDecodes() throws {
        let json = #"{"nominations":[{"requirement_id":"R1","file":"a.swift","symbol":"A","relation":"x","why_edit":"y"}]}"#
        let decoded = try JSONDecoder().decode(TargetNomination.self, from: Data(json.utf8))
        #expect(decoded.nominations.count == 1)
        #expect(try JSONDecoder().decode(TargetNomination.self, from: Data(#"{"nominations":[]}"#.utf8)).nominations.isEmpty)
    }
}
