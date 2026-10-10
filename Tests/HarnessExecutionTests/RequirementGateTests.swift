import Foundation
import HarnessCore
import Testing
@testable import HarnessExecution

/// Synthetic, task-independent checks of the Post-Implementation Requirement Gate.
/// Protected property: tests passing plus any requirement violation is never a success.
struct RequirementGateTests {
    let objective = "温度が30度を超えたら冷房を入れて。30度ちょうどのときは入れないで。表示は今のままにして。"
    let builder = "local-builder-model"
    var clauses: [ObjectiveClause] { ObjectiveClauses.segment(objective) }
    var plan: RequirementCoveragePlan {
        .init(requirements: [
            .init(requirement: "Turn cooling on above 30 degrees", source_clause_ids: ["C1"], relevant_symbols: ["Thermostat"],
                  editable_targets: ["Sources/Home/Thermostat.swift"], read_only_evidence: [], rationale: "r", coverage: "complete", no_change_reason: ""),
            .init(requirement: "Keep the display unchanged", source_clause_ids: ["C3"], relevant_symbols: ["Display"],
                  editable_targets: [], read_only_evidence: [], rationale: "r", coverage: "complete", no_change_reason: "display code is not touched")
        ])
    }
    func proposal(_ path: String, _ content: String) -> FileChangeProposal {
        .init(relativePath: path, originalContent: "old", proposedContent: content,
              diffLines: [.init(kind: .addition, oldLineNumber: nil, newLineNumber: 1, text: content)], summary: .init(addedLineCount: 1, removedLineCount: 0))
    }
    var request: RequirementVerification.Request {
        RequirementVerification.request(taskID: "task-1", objective: objective, clauses: clauses, plan: plan,
            proposals: [proposal("Sources/Home/Thermostat.swift", "var cooling: Bool { temperature > 30 }"),
                        proposal("Tests/HomeTests/HiddenAcceptance.swift", "#expect(secretExpected == 42)")],
            protected: ["Sources/Home/Protected.swift"], builderModel: builder)
    }
    func report(_ verdicts: [String: RequirementVerification.Verdict], findings: [RequirementVerification.Finding] = [],
                role: String = "independent_reviewer", identity: String = "reviewer-a") -> RequirementVerification.Report {
        .init(taskID: "task-1", verifier: .init(role: role, identity: identity),
              items: request.requiredIDs.map { .init(id: $0, verdict: verdicts[$0] ?? .SATISFIED, evidence: "checked against the diff") },
              findings: findings)
    }
    func final(_ report: RequirementVerification.Report) -> String {
        RequirementVerification.finalResult(testsPassedResult: "HARNESS_PASS",
                                            decision: RequirementVerification.decide(report, for: request))
    }

    @Test func testsPassButRequirementViolatedIsNeverSuccess() {
        // Protected: the tests-passed result is only an input; a violation always wins.
        let violated = report(["R1": .VIOLATED])
        #expect(final(violated) == RequirementVerification.falseSuccessResult)
        #expect(final(violated) != "HARNESS_PASS")
        for id in request.requiredIDs {
            #expect(final(report([id: .VIOLATED])) == "VERIFICATION_FALSE_SUCCESS")
            #expect(RequirementVerification.finalResult(testsPassedResult: "HARNESS_RECOVERED_SUCCESS",
                decision: RequirementVerification.decide(report([id: .VIOLATED]), for: request)) == "VERIFICATION_FALSE_SUCCESS")
        }
    }

    @Test func allRequirementsSatisfiedReleasesResult() {
        #expect(final(report([:])) == "HARNESS_PASS")
    }

    @Test func edgeConditionViolationFails() {
        // e.g. the boundary clause ("exactly 30: do not turn on") is violated while the main rule holds.
        let boundary = clauses.first { $0.exactSourceText.contains("ちょうど") }!.clauseID
        #expect(final(report([boundary: .VIOLATED])) == "VERIFICATION_FALSE_SUCCESS")
    }

    @Test func uncertainIsFailClosed() {
        let decision = RequirementVerification.decide(report(["R2": .UNCERTAIN]), for: request)
        #expect(decision.outcome == .REQUIREMENT_UNCERTAIN)
        #expect(RequirementVerification.finalResult(testsPassedResult: "HARNESS_PASS", decision: decision) == "REQUIREMENT_UNCERTAIN")
    }

    @Test func qualityWarningOnlyKeepsSuccessAndRecordsWarning() {
        let decision = RequirementVerification.decide(report([:], findings: [.init(kind: .QUALITY_WARNING,
            text: "duplicated threshold literal outside the objective's scope")]), for: request)
        #expect(decision.outcome == .REQUIREMENTS_SATISFIED && decision.qualityWarnings.count == 1)
        #expect(RequirementVerification.finalResult(testsPassedResult: "HARNESS_RECOVERED_SUCCESS", decision: decision) == "HARNESS_RECOVERED_SUCCESS")
    }

    @Test func violationFindingWithWarningFails() {
        let decision = RequirementVerification.decide(report([:], findings: [
            .init(kind: .REQUIREMENT_VIOLATION, text: "display text changed"), .init(kind: .QUALITY_WARNING, text: "naming")]), for: request)
        #expect(decision.outcome == .REQUIREMENT_VIOLATION && decision.qualityWarnings == ["naming"])
        #expect(RequirementVerification.finalResult(testsPassedResult: "HARNESS_PASS", decision: decision) == "VERIFICATION_FALSE_SUCCESS")
    }

    @Test func selfCertificationAndIncompleteReportsStayPending() {
        #expect(final(report([:], identity: builder)) == RequirementVerification.pendingResult)
        #expect(final(report([:], role: "builder", identity: "someone")) == RequirementVerification.pendingResult)
        let partial = RequirementVerification.Report(taskID: "task-1", verifier: .init(role: "verifier", identity: "v"),
            items: [.init(id: "R1", verdict: .SATISFIED, evidence: "ok")], findings: [])
        #expect(final(partial) == RequirementVerification.pendingResult)
        let wrongTask = RequirementVerification.Report(taskID: "other", verifier: .init(role: "verifier", identity: "v"),
            items: report([:]).items, findings: [])
        #expect(final(wrongTask) == RequirementVerification.pendingResult)
    }

    @Test func requestCarriesObjectivePlanAndProductionOnly() throws {
        let r = request
        #expect(r.clauses.map(\.id) == clauses.filter(\.mandatoryCandidate).map(\.clauseID))
        #expect(r.requirements.map(\.id) == ["R1", "R2"])
        #expect(r.productionDiff.contains("Thermostat.swift") && !r.productionDiff.contains("Hidden"))
        #expect(r.finalCode.keys.sorted() == ["Sources/Home/Thermostat.swift"])
        let encoded = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(!encoded.contains("secretExpected") && !encoded.contains("42"))
    }
}
