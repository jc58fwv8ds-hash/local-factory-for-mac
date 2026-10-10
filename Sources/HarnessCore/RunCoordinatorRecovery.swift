import Foundation

public extension RunCoordinatorWorkflow {
    static func recoverAfterRestart(
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        switch project.runCoordinator.phase {
        case .inactive:
            project.runCoordinator.currentWorkItemID = nil
        case .readyForNextItem, .readyForFinalValidation:
            project.runCoordinator.currentWorkItemID = nil
        case .awaitingChange, .awaitingValidation, .awaitingRepair, .awaitingReview:
            guard let item = currentWorkItem(in: project) else {
                blockUnavailableRecovery(in: &project, now: now)
                return
            }
            if item.status == .completed {
                recoverCompletedItem(in: &project, now: now)
                return
            }
            if project.runCoordinator.phase == .awaitingReview,
               !hasLatestSuccessfulValidation(for: item.id, in: project) {
                requireRecoveredValidation(in: &project, now: now)
            } else if project.runCoordinator.phase == .awaitingRepair,
                      !hasUnresolvedFailure(for: item.id, in: project) {
                requireRecoveredValidation(in: &project, now: now)
            }
        case .paused:
            guard project.runCoordinator.currentWorkItemID == nil
                    || currentWorkItem(in: project) != nil else {
                blockUnavailableRecovery(in: &project, now: now)
                return
            }
        case .blocked where project.runCoordinator.stopReason == .repeatedFailure:
            guard let item = currentWorkItem(in: project),
                  project.runCoordinator.consecutiveMatchingFailures >= 2,
                  project.runCoordinator.lastFailureFingerprint != nil,
                  hasUnresolvedFailure(for: item.id, in: project) else {
                blockUnavailableRecovery(in: &project, now: now)
                return
            }
        case .blocked:
            break
        }
    }

    private static func recoverCompletedItem(
        in project: inout HarnessProject,
        now: Date
    ) {
        project.runCoordinator.currentWorkItemID = nil
        project.runCoordinator.phase = nextWorkItemIndex(in: project) == nil
            ? .readyForFinalValidation
            : .readyForNextItem
        project.runCoordinator.stopReason = nil
        project.runCoordinator.updatedAt = now
    }

    private static func hasLatestSuccessfulValidation(
        for workItemID: UUID,
        in project: HarnessProject
    ) -> Bool {
        for record in project.runCoordinator.records.reversed()
        where record.workItemID == workItemID {
            switch record.event {
            case .validationSucceeded: return true
            case .changeApplied, .sourceChanged, .validationFailed: return false
            default: continue
            }
        }
        return false
    }

    private static func hasUnresolvedFailure(
        for workItemID: UUID,
        in project: HarnessProject
    ) -> Bool {
        for record in project.runCoordinator.records.reversed()
        where record.workItemID == workItemID {
            switch record.event {
            case .validationFailed: return true
            case .validationSucceeded, .approved: return false
            default: continue
            }
        }
        return false
    }

    private static func requireRecoveredValidation(
        in project: inout HarnessProject,
        now: Date
    ) {
        CreationCompletionPolicy.invalidateValidationEvidence(in: &project)
        project.runCoordinator.phase = .awaitingValidation
        project.runCoordinator.consecutiveMatchingFailures = 0
        project.runCoordinator.lastFailureFingerprint = nil
        project.runCoordinator.stopReason = nil
        project.runCoordinator.updatedAt = now
    }

    private static func blockUnavailableRecovery(
        in project: inout HarnessProject,
        now: Date
    ) {
        CreationCompletionPolicy.invalidateValidationEvidence(in: &project)
        project.runCoordinator.phase = .blocked
        project.runCoordinator.stopReason = .workItemUnavailable
        project.runCoordinator.updatedAt = now
    }
}
