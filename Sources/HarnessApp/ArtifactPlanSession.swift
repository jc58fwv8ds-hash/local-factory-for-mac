import Foundation
import HarnessCore
import Observation

enum ArtifactPlanGenerationEvent {
    case started
    case planReady
    case cancelled
    case failed(String)
}

@MainActor
@Observable
final class ArtifactPlanSession {
    var instruction = ""
    var plan: ArtifactCreationPlan?
    var isGenerating = false
    var errorMessage: String?

    @ObservationIgnored private let rootPath: String
    @ObservationIgnored private let model: ModelSelection?
    @ObservationIgnored private let editor: any ProjectFileEditing
    @ObservationIgnored private let inferenceProvider: any ModelInferenceProvider
    @ObservationIgnored private let onGenerationEvent: (ArtifactPlanGenerationEvent) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        rootPath: String,
        model: ModelSelection?,
        editor: any ProjectFileEditing,
        inferenceProvider: any ModelInferenceProvider,
        onGenerationEvent: @escaping (ArtifactPlanGenerationEvent) -> Void
    ) {
        self.rootPath = rootPath
        self.model = model
        self.editor = editor
        self.inferenceProvider = inferenceProvider
        self.onGenerationEvent = onGenerationEvent
    }

    var canGenerate: Bool {
        model != nil
            && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isGenerating
    }

    func generate(existingPaths: [String]) {
        guard canGenerate, let model else { return }
        let cleanedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        isGenerating = true
        errorMessage = nil
        plan = nil
        onGenerationEvent(.started)

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let messages = try ArtifactPlanPromptBuilder.messages(
                    instruction: cleanedInstruction,
                    existingPaths: existingPaths
                )
                let request = InferenceRequest(
                    runtime: model.runtime,
                    modelIdentifier: model.identifier,
                    messages: messages,
                    maximumOutputTokens: InferenceOutputBudget.artifactPlan,
                    structuredOutput: .artifactPlan
                )
                var response = ""
                let events = await inferenceProvider.events(for: request)
                for try await delta in events {
                    try Task.checkCancellation()
                    response += delta
                }
                try Task.checkCancellation()
                let parsedPlan = try ArtifactPlanResponseParser.plan(
                    from: response,
                    instruction: cleanedInstruction,
                    existingPaths: existingPaths
                )
                for target in parsedPlan.targets {
                    try await editor.validateCreationPath(
                        rootPath: rootPath,
                        relativePath: target.relativePath
                    )
                    try Task.checkCancellation()
                }
                plan = parsedPlan
                onGenerationEvent(.planReady)
            } catch is CancellationError {
                errorMessage = "成果物計画の生成を停止しました。"
                onGenerationEvent(.cancelled)
            } catch {
                errorMessage = error.localizedDescription
                onGenerationEvent(.failed(error.localizedDescription))
            }
            isGenerating = false
            task = nil
        }
    }

    func stop() {
        task?.cancel()
    }
}
