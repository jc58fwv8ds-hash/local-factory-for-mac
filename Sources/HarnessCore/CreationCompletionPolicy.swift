import Foundation

public enum CreationCompletionBlocker: Equatable, Sendable {
    case unavailablePhase
    case operationInProgress
    case artifactPlanIncomplete(Int)
    case repairIncomplete(Int)
    case workItemsIncomplete(Int)
    case validationRequired
    case validationFailed
}

public struct CreationCompletionReadiness: Equatable, Sendable {
    public let blocker: CreationCompletionBlocker?

    public init(blocker: CreationCompletionBlocker? = nil) {
        self.blocker = blocker
    }

    public var isReady: Bool { blocker == nil }

    public var guidance: String? {
        switch blocker {
        case nil:
            nil
        case .unavailablePhase:
            "制作の確認段階になったら完成にできます。"
        case .operationInProgress:
            "進行中または中断した作業を再開するか破棄してから完成にしてね。"
        case .artifactPlanIncomplete(let count):
            "成果物計画に未反映のファイルが\(count)件あります。順番に反映して最終検証してね。"
        case .repairIncomplete(let count):
            "修正待ちのファイルが\(count)件あります。修正を再開してから最終検証してね。"
        case .workItemsIncomplete(let count):
            "制作計画に未完了が\(count)件あります。先に仕上げてから最終検証してね。"
        case .validationRequired:
            "完成にする前に、現在のソースを検証してね。"
        case .validationFailed:
            "直近の検証が失敗しています。修正してもう一度検証してね。"
        }
    }
}

public enum CreationCompletionPolicy {
    public static func canOfferCompletion(for phase: CreationLoopPhase) -> Bool {
        phase == .awaitingHarnessReview
            || phase == .awaitingUserDecision
            || phase == .awaitingExternalReview
    }

    public static func readiness(
        for project: HarnessProject
    ) -> CreationCompletionReadiness {
        guard canOfferCompletion(for: project.creationLoop.phase) else {
            return CreationCompletionReadiness(blocker: .unavailablePhase)
        }
        guard project.operationCheckpoint == nil,
              project.computerOperationCheckpoint == nil,
              !project.runCoordinator.blocksCompletion else {
            return CreationCompletionReadiness(blocker: .operationInProgress)
        }
        if let plan = project.artifactCreationPlan, !plan.isFullyApplied {
            return CreationCompletionReadiness(
                blocker: .artifactPlanIncomplete(
                    max(0, plan.targets.count - plan.completedCount)
                )
            )
        }
        if let repair = project.repairResumeState, repair.pendingCount > 0 {
            return CreationCompletionReadiness(
                blocker: .repairIncomplete(repair.pendingCount)
            )
        }
        let incompleteWorkCount = ProjectInstructionContext.productionCandidates(in: project)
            .filter { $0.status != .completed }
            .count
        guard incompleteWorkCount == 0 else {
            return CreationCompletionReadiness(
                blocker: .workItemsIncomplete(incompleteWorkCount)
            )
        }
        switch project.creationLoop.lastValidationSucceeded {
        case .some(true):
            return CreationCompletionReadiness()
        case .some(false):
            return CreationCompletionReadiness(blocker: .validationFailed)
        case nil:
            return CreationCompletionReadiness(blocker: .validationRequired)
        }
    }

    public static func invalidateValidationEvidence(
        in project: inout HarnessProject
    ) {
        project.creationLoop.lastValidationSucceeded = nil
    }
}
