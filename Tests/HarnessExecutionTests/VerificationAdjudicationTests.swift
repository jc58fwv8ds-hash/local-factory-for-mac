import Foundation
import HarnessCore
import Testing
@testable import HarnessExecution

struct VerificationAdjudicationTests {
    @Test func independentFailureClasses() {
        let start = "Test run started\n"
        #expect(VerificationAdjudication.classify(output: start + "Expectation failed: SECRET").kind == .assertion)
        #expect(VerificationAdjudication.classify(output: start + "exited with unexpected signal code 5").kind == .signal)
        #expect(VerificationAdjudication.classify(output: start, crashReportMatched: true).kind == .crash)
        #expect(VerificationAdjudication.classify(output: start, timedOut: true).kind == .timeout)
        #expect(VerificationAdjudication.classify(output: "sandbox-exec: sandbox_apply: denied").kind == .isolation)
        #expect(VerificationAdjudication.classify(output: "Sandbox: worker deny(1) file-write").kind == .isolation)
        #expect(VerificationAdjudication.classify(output: "failed to load test bundle").kind == .infrastructure)
        #expect(VerificationAdjudication.classify(output: "error 1").kind == .unknown)
        #expect(VerificationAdjudication.classify(output: "signal 5").kind == .unknown)
    }
    @Test func denialOverridesRuntimeAndNeverRepairs() {
        let v = VerificationAdjudication.classify(output: "Test run started\nexited with unexpected signal code 9\nSandbox: worker deny(1)")
        #expect(v.kind == .isolation)
        #expect(!v.runtimeRepairEligible)
    }
    @Test func promptCannotContainHiddenEvidenceOrInferSignalCause() {
        let v = VerificationAdjudication.classify(output: "Test run started\nexited with unexpected signal code 5\nSECRET_HIDDEN_INPUT expected 731")
        let p = RuntimeRepair.feedback(verdict: v, diff: "+ own edit")
        #expect(v.runtimeRepairEligible)
        #expect(!p.contains("SECRET") && !p.contains("731") && !p.contains("overflow"))
        #expect(p.contains("TEST_RUNTIME_SIGNAL"))
    }
    @Test func budgetDoesNotGrow() {
        var budget = RequirementCoverage.Budget()
        let runtime = budget.consume(.runtimeRepair)
        let runtimeAgain = budget.consume(.runtimeRepair)
        let compiler = budget.consume(.compilerRepair)
        let replanOverCap = budget.consume(.requirementReplan)
        #expect(runtime)
        #expect(!runtimeAgain)
        #expect(compiler)
        #expect(!replanOverCap)
        #expect(RequirementCoverage.Budget.taskLimit == 2)
    }
    @Test func fingerprintsIgnoreOrderNotChangedMeaning() {
        func p(_ file: String, _ new: String) -> FileChangeProposal {
            .init(relativePath: file, originalContent: "old", proposedContent: new,
                  diffLines: [], summary: .init(addedLineCount: 1, removedLineCount: 1))
        }
        #expect(RuntimeRepair.fingerprint([p("a", "x"), p("b", "y")]) == RuntimeRepair.fingerprint([p("b", "y"), p("a", "x")]))
        #expect(RuntimeRepair.fingerprint([p("a", "x")]) != RuntimeRepair.fingerprint([p("a", "y")]))
    }
}
