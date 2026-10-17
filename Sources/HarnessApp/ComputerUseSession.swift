import Foundation
import HarnessCore
import Observation

/// The screen side of Computer Use stage 1: the goal, each step as it happens, and the approval a risky step waits for.
@MainActor
@Observable
final class ComputerUseSession {
    struct Approval: Equatable {
        let action: String
        let reason: String
    }

    var goal = ""
    var steps: [ComputerUseStep] = []
    var pendingApproval: Approval?
    var outcome: String?
    var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored let controller: any ComputerUseControlling

    init(controller: any ComputerUseControlling = AccessibilityComputerUse()) {
        self.controller = controller
    }

    func start(model: ModelSelection, provider: any ModelInferenceProvider) {
        let goal = self.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !isRunning else { return }
        steps = []
        outcome = nil
        isRunning = true
        let controller = self.controller
        task = Task { [weak self] in
            weak let session = self
            let result = await ComputerUseAgent.run(
                goal: goal, controller: controller,
                decide: { messages in
                    var reply = ""
                    let request = InferenceRequest(runtime: model.runtime, modelIdentifier: model.identifier, messages: messages,
                                                   maximumOutputTokens: 400, temperature: 0)
                    for try await piece in await provider.events(for: request) { reply += piece }
                    return reply
                },
                approve: { action, reason in await session?.askApproval(action: action, reason: reason) ?? false },
                onStep: { step in await session?.append(step) })
            self?.finish(result)
        }
    }

    func answer(_ approved: Bool) {
        pendingApproval = nil
        approvalContinuation?.resume(returning: approved)
        approvalContinuation = nil
    }

    func stop() {
        task?.cancel()
        answer(false)
    }

    private func askApproval(action: String, reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            pendingApproval = Approval(action: action, reason: reason)
        }
    }

    private func append(_ step: ComputerUseStep) { steps.append(step) }

    private func finish(_ result: ComputerUseOutcome) {
        isRunning = false
        task = nil
        switch result {
        case .done(let summary): outcome = "完了しました: \(summary)"
        case .needsUser(let message): outcome = "あなたの操作が必要です: \(message)"
        case .stopped(let message): outcome = "止めました: \(message)"
        case .stepLimit: outcome = "\(ComputerUseAgent.maximumSteps) 手で終わらなかったので止めました。続けるときは、目的を細かくして頼み直してください。"
        }
    }
}
