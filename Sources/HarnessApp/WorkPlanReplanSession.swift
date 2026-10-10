import Foundation
import HarnessCore
import Observation

@MainActor
@Observable
final class WorkPlanReplanSession {
    private(set) var proposal: WorkPlanReplanProposal?
    private(set) var isGenerating = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let model: ModelSelection?
    @ObservationIgnored private let inference: any ModelInferenceProvider
    @ObservationIgnored private var task: Task<Void, Never>?

    init(model: ModelSelection?, inference: any ModelInferenceProvider) {
        self.model = model
        self.inference = inference
    }

    var canGenerate: Bool { model != nil && !isGenerating }

    func generate(
        project: HarnessProject,
        report: ProjectValidationReport,
        analysis: BuildFailureAnalysis?
    ) {
        guard canGenerate, let model else { return }
        stop()
        proposal = nil
        errorMessage = nil
        isGenerating = true
        task = Task { [weak self, inference] in
            guard let self else { return }
            do {
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
                var response = ""
                for try await fragment in await inference.events(for: request) {
                    try Task.checkCancellation()
                    guard response.count + fragment.count <= 32_000 else {
                        throw WorkPlanReplanError.invalidResponse
                    }
                    response += fragment
                }
                try Task.checkCancellation()
                proposal = try WorkPlanReplanResponseParser.proposal(
                    from: response,
                    context: context
                )
            } catch is CancellationError {
                errorMessage = "制作計画の見直しを停止しました。"
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
            task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isGenerating = false
    }

    func discard() {
        stop()
        proposal = nil
        errorMessage = nil
    }
}
