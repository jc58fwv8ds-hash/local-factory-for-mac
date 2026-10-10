import Foundation
import HarnessCore
import Observation

struct ComputerOperationResult: Identifiable, Equatable {
    let id = UUID()
    let step: ComputerOperationStep
    let succeeded: Bool
    let message: String
    let summaryEvidence: ComputerOperationEvidence
    let wasSkipped: Bool
    let completedAt = Date()

    init(
        step: ComputerOperationStep,
        succeeded: Bool,
        message: String,
        summaryEvidence: ComputerOperationEvidence,
        wasSkipped: Bool = false
    ) {
        self.step = step
        self.succeeded = succeeded
        self.message = message
        self.summaryEvidence = summaryEvidence
        self.wasSkipped = wasSkipped
    }
}

enum ComputerOperatorPreparation: Equatable {
    case ready
    case busy
    case recoveryRequired
}

@MainActor
@Observable
final class ComputerOperatorSession {
    var instruction = ""
    var plan: ComputerOperationPlan?
    var results: [ComputerOperationResult] = []
    var resultSummary: String?
    var recoveryNotice: String?
    var isPlanning = false
    var isRunning = false
    var isSummarizing = false
    var errorMessage: String?
    private(set) var nextStepIndex = 0
    private(set) var uncertainStepIndex: Int?
    private(set) var skippedStepIndexes = Set<Int>()

    @ObservationIgnored let inferenceProvider: any ModelInferenceProvider
    @ObservationIgnored let validationProvider: any ProjectValidating
    @ObservationIgnored let controller = MacComputerController()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeProjectID: UUID?
    @ObservationIgnored private var checkpointStartedAt = Date()
    @ObservationIgnored private var resultHandler: ((UUID, ComputerOperationResult) -> Void)?
    @ObservationIgnored private var checkpointHandler: ((UUID, ComputerOperationCheckpoint?) -> Void)?

    init(
        inferenceProvider: any ModelInferenceProvider,
        validationProvider: any ProjectValidating
    ) {
        self.inferenceProvider = inferenceProvider
        self.validationProvider = validationProvider
    }

    var hasAccessibilityPermission: Bool {
        controller.hasAccessibilityPermission
    }

    var isBusy: Bool {
        isPlanning || isRunning || isSummarizing
    }

    var canPlan: Bool {
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isBusy
    }

    var canRun: Bool {
        guard let plan else { return false }
        return nextStepIndex < plan.steps.count
            && uncertainStepIndex == nil
            && !isBusy
    }

    var remainingStepCount: Int {
        guard let plan else { return 0 }
        return max(plan.steps.count - nextStepIndex, 0)
    }

    func configureResultHandler(
        _ handler: @escaping (UUID, ComputerOperationResult) -> Void
    ) {
        resultHandler = handler
    }

    func configureCheckpointPersistence(
        _ handler: @escaping (UUID, ComputerOperationCheckpoint?) -> Void
    ) {
        checkpointHandler = handler
    }

    func restore(project: HarnessProject) {
        guard !isBusy else { return }
        if activeProjectID == project.id,
           plan != nil || !instruction.isEmpty { return }
        activeProjectID = project.id
        clearTransientState(keepingInstruction: false)
        guard let checkpoint = project.computerOperationCheckpoint else { return }
        instruction = checkpoint.instruction
        plan = checkpoint.plan
        nextStepIndex = checkpoint.nextStepIndex
        uncertainStepIndex = checkpoint.uncertainStepIndex
        checkpointStartedAt = checkpoint.startedAt
        recoveryNotice = checkpoint.requiresUserDecision
            ? "前回は手順\((checkpoint.uncertainStepIndex ?? 0) + 1)の途中で終了しました。実行済みか断定せず、もう一度行うか飛ばすか確認してください。"
            : "前回の続きから再開できます。完了した手順を勝手に繰り返しません。"
    }

    func prepareInstruction(
        _ value: String,
        for project: HarnessProject
    ) -> ComputerOperatorPreparation {
        guard !isBusy else { return .busy }
        guard project.computerOperationCheckpoint == nil else {
            return .recoveryRequired
        }
        activeProjectID = project.id
        clearTransientState(keepingInstruction: false)
        instruction = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return .ready
    }

    func makePlan(project: HarnessProject, rootPath: String?) {
        guard canPlan, let model = project.selectedModel else {
            errorMessage = project.selectedModel == nil ? "先にAIモデルを選択してください。" : nil
            return
        }
        let requestedInstruction = instruction
        activeProjectID = project.id
        checkpointStartedAt = .now
        isPlanning = true
        errorMessage = nil
        recoveryNotice = nil
        resultSummary = nil
        plan = nil
        results = []
        nextStepIndex = 0
        uncertainStepIndex = nil

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let messages = try ComputerOperationPromptBuilder.messages(
                    instruction: requestedInstruction,
                    project: project,
                    hasSource: rootPath != nil
                )
                let request = InferenceRequest(
                    runtime: model.runtime,
                    modelIdentifier: model.identifier,
                    messages: messages,
                    maximumOutputTokens: InferenceOutputBudget.computerPlan,
                    structuredOutput: .computerPlan
                )
                var response = ""
                let events = await inferenceProvider.events(for: request)
                for try await delta in events {
                    try Task.checkCancellation()
                    response += delta
                }
                try Task.checkCancellation()
                plan = try ComputerOperationPlanParser.parse(response)
                persistCheckpoint()
            } catch is CancellationError {
                errorMessage = "操作案の作成を停止しました。"
            } catch {
                errorMessage = error.localizedDescription
            }
            isPlanning = false
            task = nil
        }
    }

    func execute(project: HarnessProject, rootPath: String?) {
        guard canRun, let plan else { return }
        guard activeProjectID == project.id else {
            errorMessage = "この操作案は別のプロジェクト用です。対象を戻すか、新しい操作案を作ってください。"
            return
        }
        isRunning = true
        errorMessage = nil
        resultSummary = nil
        recoveryNotice = nil

        task = Task { [weak self] in
            guard let self else { return }
            var stoppedByFailure = false
            for index in nextStepIndex..<plan.steps.count {
                guard !Task.isCancelled else { break }
                uncertainStepIndex = index
                persistCheckpoint()
                let result = await execute(plan.steps[index], rootPath: rootPath)
                guard !Task.isCancelled else { break }
                results.append(result)
                if let projectID = activeProjectID {
                    resultHandler?(projectID, result)
                }
                uncertainStepIndex = nil
                if result.succeeded {
                    nextStepIndex = index + 1
                } else {
                    nextStepIndex = index
                    stoppedByFailure = true
                }
                persistCheckpoint(clearIfFinished: true)
                if stoppedByFailure { break }
            }
            isRunning = false
            if Task.isCancelled, let index = uncertainStepIndex {
                recoveryNotice = interruptedOperationMessage(stepIndex: index)
            }
            if !Task.isCancelled, !results.isEmpty {
                await summarizeResults(project: project)
            }
            task = nil
        }
    }

    func resolveUncertainStep(retry: Bool) {
        guard !isBusy, let index = uncertainStepIndex, let plan else { return }
        nextStepIndex = retry ? index : index + 1
        uncertainStepIndex = nil
        if retry {
            recoveryNotice = "この手順はまだ再実行していません。計画を実行する前に、もう一度確認画面を表示します。"
        } else {
            skippedStepIndexes.insert(index)
            recordSkippedStep(plan.steps[index])
            recoveryNotice = nextStepIndex == plan.steps.count
                ? "前回の不明な手順は飛ばし、計画を終了しました。"
                : "前回の不明な手順は飛ばしました。残りの手順だけを続けられます。"
        }
        persistCheckpoint(clearIfFinished: true)
        if nextStepIndex == plan.steps.count {
            resultSummary = "前回の不明な手順は再実行せず、この計画を終了しました。"
        }
    }

    func stop() {
        task?.cancel()
    }

    func reset() {
        guard !isBusy else { return }
        let projectID = activeProjectID
        clearTransientState(keepingInstruction: true)
        if let projectID { checkpointHandler?(projectID, nil) }
    }

    func openAccessibilitySettings() {
        controller.openAccessibilitySettings()
    }

    private func persistCheckpoint(clearIfFinished: Bool = false) {
        guard let projectID = activeProjectID, let plan else { return }
        if clearIfFinished, nextStepIndex >= plan.steps.count,
           uncertainStepIndex == nil {
            checkpointHandler?(projectID, nil)
            return
        }
        checkpointHandler?(
            projectID,
            ComputerOperationCheckpoint(
                instruction: instruction,
                plan: plan,
                nextStepIndex: nextStepIndex,
                uncertainStepIndex: uncertainStepIndex,
                startedAt: checkpointStartedAt,
                updatedAt: .now
            )
        )
    }

    private func clearTransientState(keepingInstruction: Bool) {
        if !keepingInstruction { instruction = "" }
        plan = nil
        results = []
        resultSummary = nil
        recoveryNotice = nil
        errorMessage = nil
        nextStepIndex = 0
        uncertainStepIndex = nil
        skippedStepIndexes = []
    }

    private func interruptedOperationMessage(stepIndex: Int) -> String {
        "手順\(stepIndex + 1)を実行中に停止しました。処理済みか断定せず、もう一度行うか飛ばすか確認してください。"
    }

    private func recordSkippedStep(_ step: ComputerOperationStep) {
        let skipped = ComputerOperationResult(
            step: step,
            succeeded: false,
            message: "不確定な操作を再実行せず、ユーザーの選択で飛ばしました。",
            summaryEvidence: ComputerOperationEvidence(
                kind: step.kind,
                succeeded: false,
                detail: "不確定な操作は再実行せず、ユーザーがスキップしました。"
            ),
            wasSkipped: true
        )
        results.append(skipped)
        if let projectID = activeProjectID {
            resultHandler?(projectID, skipped)
        }
    }
}
