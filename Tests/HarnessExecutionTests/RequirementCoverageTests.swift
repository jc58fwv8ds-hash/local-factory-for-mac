import Foundation
import HarnessCore
import Testing
@testable import HarnessExecution

/// Synthetic, task-independent checks of the coverage plan gate, Harness-driven
/// under-escalation detection, bounded recovery and leak-free replan feedback.
struct RequirementCoverageTests {
    let sources: [String: String] = [
        "Sources/Trip/Itinerary.swift": "struct Itinerary { var stops: [Stop] = []; func total() -> Int { stops.count } }",
        "Sources/Trip/Stop.swift": "struct Stop { let name: String; let minutes: Int; var isLong: Bool { minutes > 90 } }",
        "Sources/Trip/Weather.swift": "struct Weather { let celsius: Int }"
    ]
    let editable: Set<String> = ["Sources/Trip/Itinerary.swift"]
    let readOnly: Set<String> = ["Sources/Trip/Stop.swift"]
    typealias Item = RequirementCoveragePlan.Item
    func item(_ req: String, symbols: [String], targets: [String], evidence: [String] = [],
              coverage: String = "complete", reason: String? = nil) -> Item {
        .init(requirement: req, relevant_symbols: symbols, editable_targets: targets,
              read_only_evidence: evidence, rationale: "because", coverage: coverage, no_change_reason: reason)
    }

    @Test func twoRequirementsOneTargetDetectsUnderEscalationWithoutContextRequest() {
        // Requirement 2 needs a new property on Stop (owned by read-only evidence);
        // the model neither lists Stop.swift as a target nor cites it, and sends no request.
        let plan = RequirementCoveragePlan(requirements: [
            item("sum minutes in Itinerary", symbols: ["Itinerary", "total"], targets: ["Sources/Trip/Itinerary.swift"]),
            item("mark each stop as scenic", symbols: ["Stop", "isScenic"], targets: ["Sources/Trip/Itinerary.swift"])
        ])
        let a = RequirementCoverage.assess(plan, editable: editable, readOnly: readOnly, sources: sources)
        #expect(a.status == .needsContextReplan)
        #expect(a.uncovered == ["mark each stop as scenic"])
        #expect(a.relatedEvidence == ["Sources/Trip/Stop.swift"])
        #expect(a.requestedFiles.isEmpty) // detection never promotes anything by itself
    }

    @Test func incompleteCoverageWithRelatedEvidenceNeedsReplan() {
        let plan = RequirementCoveragePlan(requirements: [
            item("stops expose duration", symbols: ["minutes"], targets: [], evidence: ["Sources/Trip/Stop.swift"], coverage: "uncertain")
        ])
        #expect(RequirementCoverage.assess(plan, editable: editable, readOnly: readOnly, sources: sources).status == .needsContextReplan)
    }

    @Test func fullyCoveredPlanIsReadyAndNeverReplans() {
        let plan = RequirementCoveragePlan(requirements: [
            item("sum minutes", symbols: ["Itinerary", "Stop", "minutes"], targets: ["Sources/Trip/Itinerary.swift"],
                 evidence: ["Sources/Trip/Stop.swift"]),
            item("weather unaffected", symbols: [], targets: [], reason: "no weather change requested")
        ])
        let a = RequirementCoverage.assess(plan, editable: editable, readOnly: readOnly, sources: sources)
        #expect(a.status == .ready && a.uncovered.isEmpty)
    }

    @Test func planNamingReadOnlyFileRequestsVerificationNotPromotion() {
        let plan = RequirementCoveragePlan(requirements: [
            item("add isScenic to Stop", symbols: ["Stop"], targets: ["Sources/Trip/Stop.swift"])
        ])
        let a = RequirementCoverage.assess(plan, editable: editable, readOnly: readOnly, sources: sources)
        #expect(a.status == .planRequestsEscalation && a.requestedFiles == ["Sources/Trip/Stop.swift"])
        // Promotion only happens through ContextEscalation's deterministic evidence.
        let d = ContextEscalation.evaluate(.init(file: "Sources/Trip/Stop.swift", symbol: nil, why_needed: "add isScenic",
            relation: "plan target", operation: "edit"), objective: "x", targets: Array(editable),
            contextSet: Array(editable.union(readOnly)), sources: sources, protected: [])
        #expect(d.accepted && d.promoteToEditable == ["Sources/Trip/Stop.swift"])
    }

    @Test func inventedOrUnrelatedTargetsNeverWidenScope() {
        let invented = RequirementCoveragePlan(requirements: [
            item("x", symbols: ["Hotel"], targets: ["Sources/Trip/Hotel.swift"])
        ])
        let a = RequirementCoverage.assess(invented, editable: editable, readOnly: readOnly, sources: sources)
        #expect(a.invalidTargets == ["Sources/Trip/Hotel.swift"] && a.requestedFiles.isEmpty && a.status != .ready)
        let unrelated = ContextEscalation.evaluate(.init(file: "Sources/Trip/Weather.swift", symbol: nil, why_needed: "w",
            relation: "plan target", operation: "edit"), objective: "x", targets: Array(editable),
            contextSet: Array(editable.union(readOnly)), sources: sources, protected: [])
        #expect(!unrelated.accepted && unrelated.promoteToEditable.isEmpty)
    }

    @Test func uncoveredWithoutRelatedEvidenceIsIncomplete() {
        let plan = RequirementCoveragePlan(requirements: [item("x", symbols: ["Zzzz"], targets: [], coverage: "incomplete")])
        #expect(RequirementCoverage.assess(plan, editable: editable, readOnly: readOnly, sources: sources).status == .incomplete)
    }

    @Test func eachRecoveryKindOnceAndTaskBudgetCapsChaining() {
        var budget = RequirementCoverage.Budget()
        let first = budget.consume(.compilerRepair)
        let repeated = budget.consume(.compilerRepair) // repeated failure class: stop
        let replan = budget.consume(.requirementReplan)
        let overCap = budget.consume(.contextReplan) // task-wide cap of 2 reached
        #expect(first && !repeated && replan && !overCap)
        #expect(!budget.allows(.contextReplan))
        #expect(budget.used == [.compilerRepair, .requirementReplan])
    }

    @Test func verificationFeedbackIsAbstractAndCarriesOnlyModelArtifacts() {
        let plan = RequirementCoveragePlan(requirements: [item("sum minutes", symbols: ["total"], targets: ["Sources/Trip/Itinerary.swift"])])
        let feedback = RequirementCoverage.verificationFeedback(previousPlan: plan, diff: "+func total() -> Int { 0 }")
        #expect(feedback.contains("some of the original requirements are not met"))
        #expect(feedback.contains("sum minutes") && feedback.contains("+func total()"))
        for leak in ["#expect", "XCTAssert", "Tests/", "expected", "Acceptance", "failed after"] {
            #expect(!feedback.contains(leak))
        }
        let prompt = try? RequirementCoverage.planPrompt(objective: "o", editable: ["Sources/Trip/Itinerary.swift": "a"],
            readOnly: ["Sources/Trip/Stop.swift": "b"], feedback: feedback)
        #expect(prompt?.contains("Harness feedback: Your previous change compiled") == true)
    }

    @Test func symbolAlsoDeclaredByAnotherEditableFileIsNotUnderEscalation() {
        // `minutes` is declared by read-only Stop.swift AND by editable Leg.swift; a
        // requirement targeting Itinerary.swift that mentions it is not under-escalated.
        var files = sources; files["Sources/Trip/Leg.swift"] = "struct Leg { let minutes: Int }"
        let plan = RequirementCoveragePlan(requirements: [
            item("sort by minutes", symbols: ["minutes"], targets: ["Sources/Trip/Itinerary.swift"])
        ])
        let a = RequirementCoverage.assess(plan, editable: editable.union(["Sources/Trip/Leg.swift"]),
            readOnly: readOnly, sources: files)
        #expect(a.status == .ready)
    }

    @Test func assessmentIsDeterministic() {
        let plan = RequirementCoveragePlan(requirements: [
            item("mark scenic", symbols: ["Stop", "minutes"], targets: ["Sources/Trip/Itinerary.swift"]),
            item("sum", symbols: ["Itinerary"], targets: ["Sources/Trip/Itinerary.swift"])
        ])
        let runs = (0..<5).map { _ in RequirementCoverage.assess(plan, editable: editable, readOnly: readOnly, sources: sources) }
        #expect(Set(runs.map(\.relatedEvidence)).count == 1 && Set(runs.map(\.uncovered)).count == 1)
    }

    @Test func newFileInExistingTargetIsCreatableWithinBound() {
        let invalid = ["Sources/Trip/Route.swift", "Sources/Trip/Leg.swift", "Sources/Trip/Zone.swift"]
        #expect(RequirementCoverage.creatableFiles(invalid, sources: sources, protected: []) == ["Sources/Trip/Leg.swift", "Sources/Trip/Route.swift"])
        #expect(RequirementCoverage.creatableFiles(invalid, sources: sources, protected: [], alreadyCreated: 1) == ["Sources/Trip/Leg.swift"])
        #expect(RequirementCoverage.creatableFiles(invalid, sources: sources, protected: [], alreadyCreated: 2).isEmpty)
    }

    @Test func newFileOutsideAnExistingTargetIsNotCreatable() {
        let invalid = ["Sources/Other/Route.swift", "Sources/Trip/Sub/Route.swift", "Tests/TripTests/RouteTests.swift",
                       "Package.swift", "Sources/Trip/route.swift", "Sources/Trip/../Route.swift", "Sources\\Trip\\Route.swift",
                       "Sources/Trip/Route.txt", "Sources/Trip/Itinerary.swift"]
        #expect(RequirementCoverage.creatableFiles(invalid, sources: sources, protected: []).isEmpty)
        #expect(RequirementCoverage.creatableFiles(["Sources/Trip/Route.swift"], sources: sources,
                                                   protected: ["Sources/Trip/Route.swift"]).isEmpty)
    }

    @Test func emptiedProductionSourceIsRetiredWithAComment() {
        #expect(RecordedBatchProposal.retiringEmptySource("Sources/Trip/Old.swift", " \n") == RecordedBatchProposal.retiredSourceContent)
        #expect(RecordedBatchProposal.retiringEmptySource("Tests/TripTests/OldTests.swift", "") == "")
        #expect(RecordedBatchProposal.retiringEmptySource("Sources/Trip/Old.swift", "struct A {}\n") == "struct A {}\n")
    }

    @Test func clauseReplanKeepsPreviousRequirementsOnlyForDroppedClauses() {
        func item(_ text: String, _ ids: [String]) -> RequirementCoveragePlan.Item {
            .init(requirement: text, source_clause_ids: ids, relevant_symbols: [], editable_targets: ["Sources/Trip/Itinerary.swift"],
                  read_only_evidence: [], rationale: "r", coverage: "complete", no_change_reason: "")
        }
        let previous = RequirementCoveragePlan(requirements: [item("a", ["C1"]), item("b", ["C2", "C3"]), item("c", ["C4"])])
        let replan = RequirementCoveragePlan(requirements: [item("a", ["C1"]), item("d", ["C5"])])
        let merged = RequirementCoverage.carryingOver(replan, previous: previous, uncovered: ["C3"])
        #expect(merged.requirements.map(\.requirement) == ["a", "d", "b"])
        #expect(RequirementCoverage.carryingOver(replan, previous: previous, uncovered: []).requirements.count == 2)
    }

    @Test func foundationImportIsAddedOnlyWhenNeeded() {
        let uses = "struct A { func f(_ s: String) -> [String] { s.components(separatedBy: \",\") } }\n"
        #expect(RecordedBatchProposal.addingFoundationImport("Sources/T/A.swift", uses) == "import Foundation\n\n" + uses)
        #expect(RecordedBatchProposal.addingFoundationImport("Sources/T/A.swift", "import Foundation\n" + uses) == "import Foundation\n" + uses)
        #expect(RecordedBatchProposal.addingFoundationImport("Sources/T/A.swift", "import os\n" + uses) == "import os\n" + uses)
        #expect(RecordedBatchProposal.addingFoundationImport("Sources/T/A.swift", "struct A { var x = 1 }\n") == "struct A { var x = 1 }\n")
        #expect(RecordedBatchProposal.addingFoundationImport("Tests/TTests/A.swift", uses) == uses)
    }

    @Test func repairPromptGetsDeclarationsOfQuotedPackageTypes() {
        let diagnostics = [CompilerRepair.Diagnostic(path: "Sources/Trip/Itinerary.swift", line: 1, column: 1,
                                                     message: "value of type 'Stop' has no member 'title'")]
        let text = CompilerRepair.typeDeclarations(diagnostics: diagnostics, sources: sources)
        #expect(text.contains("// Sources/Trip/Stop.swift") && text.contains("let name: String"))
        #expect(!text.contains("Weather"))
        let none = [CompilerRepair.Diagnostic(path: "a", line: 1, column: 1, message: "value of type 'String' has no member 'x'")]
        #expect(CompilerRepair.typeDeclarations(diagnostics: none, sources: sources).isEmpty)
    }

    @Test func fileNamedAfterAnExistingTypeIsNotCreated() {
        // Stop is declared in Stop.swift; a plan naming "Sources/Trip/Weather2.swift" is new, "Sources/Trip/Itinerary2.swift"
        // too, but "Sources/Trip/Weather.swift" exists and a guessed "Sources/Trip/Stops/Stop.swift" is nested.
        var moved = sources
        moved["Sources/Trip/Legs.swift"] = moved.removeValue(forKey: "Sources/Trip/Stop.swift")
        #expect(RequirementCoverage.creatableFiles(["Sources/Trip/Stop.swift"], sources: moved, protected: []).isEmpty)
        #expect(RequirementCoverage.creatableFiles(["Sources/Trip/Route.swift"], sources: moved, protected: []) == ["Sources/Trip/Route.swift"])
    }

    @Test func replanAttemptGetsItsOwnCompilerRepairOutsideTheCap() {
        var budget = RequirementCoverage.Budget()
        let steps = [budget.consume(.compilerRepair), budget.consume(.requirementReplan),
                     budget.consume(.runtimeRepair),          // task cap reached
                     budget.consume(.replanCompilerRepair),   // second attempt may still repair its compile error once
                     budget.consume(.replanCompilerRepair), budget.consume(.compilerRepair)]
        #expect(steps == [true, true, false, true, false, false])
    }
}
