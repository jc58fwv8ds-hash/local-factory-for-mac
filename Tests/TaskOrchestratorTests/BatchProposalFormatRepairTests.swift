import Foundation
import HarnessCore
import HarnessExecution
import Testing
@testable import TaskOrchestrator

struct BatchProposalFormatRepairTests {
    let existing = "Sources/Kit/Formatter.swift", added = "Sources/Kit/NewFile.swift"

    func batch(_ operation: String, _ file: String) throws -> StructuredEditBatch {
        try JSONDecoder().decode(StructuredEditBatch.self, from: Data("""
            {"edits":[{"operation":"\(operation)","file":"\(file)","expected_old_text":"","new_text":"func f() {}"}]}
            """.utf8))
    }

    @Test func aCutOffListIsRetriedWithACompactnessNote() throws {
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unexpected end of file"))
        let problem = try #require(BatchProposalStage.formatProblem(decoding, batch: nil, appendOnly: []))
        #expect(problem.cutOff && problem.feedback.contains("cut off"))
        struct Server: Error, CustomStringConvertible { var description: String { "structured output was incomplete (finish_reason=length)" } }
        #expect(BatchProposalStage.formatProblem(Server(), batch: nil, appendOnly: [])?.cutOff == true)
    }

    @Test func appendingToAnExistingFileIsRetriedButOtherScopeViolationsAreNot() throws {
        let problem = try #require(BatchProposalStage.formatProblem(StructuredEditError.scopeViolation,
            batch: try batch("append_block", existing), appendOnly: [added]))
        #expect(!problem.cutOff && problem.feedback.contains(existing) && problem.feedback.contains("replace_exact"))
        #expect(BatchProposalStage.formatProblem(StructuredEditError.scopeViolation,
            batch: try batch("append_block", added), appendOnly: [added]) == nil)
        #expect(BatchProposalStage.formatProblem(StructuredEditError.ambiguousAnchor,
            batch: try batch("append_block", existing), appendOnly: []) == nil)
    }

    @Test func theFormatRepairDoesNotConsumeTheRecoveryCap() {
        var budget = RequirementCoverage.Budget()
        let steps = [budget.consume(.formatRepair), budget.consume(.formatRepair),
                     budget.consume(.targetReplan), budget.consume(.requirementReplan)]
        #expect(steps == [true, false, true, true])
    }
}
