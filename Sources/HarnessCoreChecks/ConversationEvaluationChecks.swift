import Foundation
import HarnessCore

/// Opt-in output collection, not an LLM judge. Review semantic quality using each fixture's rubric.
enum ConversationEvaluationChecks {
    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let label = environment["HARNESS_CONVERSATION_EVAL_LABEL"] ?? "unlabelled"
        let trials = Int(environment["HARNESS_CONVERSATION_EVAL_TRIALS"] ?? "1") ?? 0
        try expect((1...3).contains(trials), "Conversation evaluation trials must be 1...3")
        let entry = try require(ModelCatalogEntry.recommended.first)
        let identifier = try require(entry.identifier(for: .ollama))
        let inference = LocalInferenceService()
        var failureCount = 0
        let suite = environment["HARNESS_CONVERSATION_EVAL_SUITE"] ?? "conversation"
        try expect(["conversation", "explanation"].contains(suite), "Unknown conversation evaluation suite")
        let scenarios = suite == "explanation" ? ExplanationEvaluationScenarios.all : ConversationEvaluationScenarios.all

        for scenario in scenarios {
            for trial in 1...trials {
                let projectBefore = scenario.project
                let request = InferenceRequest(
                    runtime: .ollama, modelIdentifier: identifier,
                    messages: ProjectPromptBuilder.messages(for: scenario.project, sourceContext: scenario.source),
                    maximumOutputTokens: InferenceOutputBudget.conversation
                )
                let start = Date()
                var output = ""
                var timing: InferenceResponseTiming?
                var failure: String?
                do {
                    let result = try await collect(request, using: inference)
                    output = result.output
                    timing = result.timing
                    try expect(!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty evaluation response")
                    try expect(scenario.project == projectBefore, "Evaluation mutated the project")
                } catch {
                    failure = error.localizedDescription
                    failureCount += 1
                }
                let report = ConversationEvaluationReport(
                    label: label, scenario: scenario.id, trial: trial, model: identifier,
                    promptCharacters: request.messages.reduce(0) { $0 + $1.content.count },
                    seconds: Date().timeIntervalSince(start), output: output,
                    timing: timing, error: failure, reviewCriteria: scenario.reviewCriteria
                )
                let data = try JSONEncoder().encode(report)
                FileHandle.standardOutput.write(data + Data("\n".utf8))
            }
        }
        try expect(failureCount == 0, "\(failureCount) conversation evaluation calls failed; inspect the reports")
        print("Conversation outputs collected. Semantic quality requires review; no automatic quality pass is claimed.")
    }

    private static func collect(
        _ request: InferenceRequest,
        using inference: any ModelInferenceProvider
    ) async throws -> TimedEvaluationResponse {
        try await withThrowingTaskGroup(of: TimedEvaluationResponse.self) { group in
            group.addTask {
                var output = ""
                var timer = InferenceResponseTimer(request: request)
                for try await delta in await inference.events(for: request) {
                    try Task.checkCancellation()
                    output += delta
                    timer.observe(hasVisibleContent: !ConversationResponseText.visibleText(
                        output, isComplete: false
                    ).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                try Task.checkCancellation()
                timer.observe(hasVisibleContent: !ConversationResponseText.visibleText(output)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                return TimedEvaluationResponse(output: output, timing: timer.measurement())
            }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                throw CheckFailure(description: "Conversation evaluation exceeded 180 seconds")
            }
            defer { group.cancelAll() }
            return try await require(group.next())
        }
    }
}

private struct TimedEvaluationResponse: Sendable {
    let output: String
    let timing: InferenceResponseTiming
}

private struct ConversationEvaluationReport: Encodable {
    let label: String
    let scenario: String
    let trial: Int
    let model: String
    let promptCharacters: Int
    let seconds: Double
    let output: String
    let timing: InferenceResponseTiming?
    let error: String?
    let reviewCriteria: [String]
}
