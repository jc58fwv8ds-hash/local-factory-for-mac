import Testing
@testable import HarnessCore

struct OutputBudgetTests {
    /// A large file's budget reaches the request instead of being cut to 4,096 (2026-11-13).
    @Test func aLargeFileKeepsItsBudgetInTheRequest() {
        let budget = InferenceOutputBudget.fileChange(existingBytes: 19_000)
        #expect(budget > 4_096)
        let request = InferenceRequest(runtime: .backburner, modelIdentifier: "m", messages: [], maximumOutputTokens: budget)
        #expect(request.maximumOutputTokens == budget)
    }
}
