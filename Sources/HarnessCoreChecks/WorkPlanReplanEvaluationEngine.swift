import Foundation
import HarnessCore

struct WorkPlanReplanEvaluationEngine {
    let model: ModelSelection
    private let inference: any ModelInferenceProvider

    init(
        model: ModelSelection,
        inference: any ModelInferenceProvider = LocalInferenceService()
    ) {
        self.model = model
        self.inference = inference
    }

    static func recommended() throws -> WorkPlanReplanEvaluationEngine {
        let entry = try require(ModelCatalogEntry.recommended.first)
        let identifier = try require(entry.identifier(for: .ollama))
        return WorkPlanReplanEvaluationEngine(
            model: ModelSelection(
                identifier: identifier,
                displayName: entry.displayName,
                runtime: .ollama
            )
        )
    }

    func propose(
        project: HarnessProject,
        report: ProjectValidationReport,
        analysis: BuildFailureAnalysis?
    ) async throws -> WorkPlanReplanEvaluationResult {
        let context = try WorkPlanReplanContextBuilder.make(
            project: project,
            report: report,
            analysis: analysis
        )
        let request = InferenceRequest(
            runtime: model.runtime,
            modelIdentifier: model.identifier,
            messages: WorkPlanReplanPromptBuilder.messages(context: context),
            maximumOutputTokens: InferenceOutputBudget.workPlanReplan,
            structuredOutput: .workPlanReplan
        )
        let started = Date()
        let raw = try await collect(request)
        return WorkPlanReplanEvaluationResult(
            context: context,
            proposal: try WorkPlanReplanResponseParser.proposal(
                from: raw,
                context: context
            ),
            seconds: Date().timeIntervalSince(started)
        )
    }

    private func collect(_ request: InferenceRequest) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [inference] in
                var output = ""
                for try await fragment in await inference.events(for: request) {
                    try Task.checkCancellation()
                    guard output.count + fragment.count <= 32_000 else {
                        throw InferenceError.invalidResponse
                    }
                    output += fragment
                }
                try Task.checkCancellation()
                return output
            }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                throw CheckFailure(description: "Work-plan replan evaluation exceeded 180 seconds")
            }
            defer { group.cancelAll() }
            return try await require(group.next())
        }
    }
}

struct WorkPlanReplanEvaluationResult {
    let context: WorkPlanReplanContext
    let proposal: WorkPlanReplanProposal
    let seconds: TimeInterval
}
