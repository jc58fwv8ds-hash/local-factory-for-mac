import Foundation
import HarnessCore
import Testing

struct CreationCompletionPolicyTests {
    @Test func completionRequiresFinishedWorkAndFreshSuccessfulValidation() throws {
        var project = makeProject(status: .pending)

        #expect(
            CreationCompletionPolicy.readiness(for: project).blocker
                == .workItemsIncomplete(1)
        )

        let itemID = try #require(project.workItems.first?.id)
        try ProjectWorkPlanWorkflow.setStatus(.completed, for: itemID, in: &project)
        #expect(
            CreationCompletionPolicy.readiness(for: project).blocker
                == .validationRequired
        )

        CreationLoopWorkflow.completedValidation(succeeded: true, in: &project)
        #expect(CreationCompletionPolicy.readiness(for: project).isReady)

        try ProjectWorkPlanWorkflow.update(
            itemID,
            from: WorkItemDraft(title: "仕上げ直す", status: .completed),
            in: &project
        )
        #expect(project.creationLoop.lastValidationSucceeded == nil)
        #expect(
            CreationCompletionPolicy.readiness(for: project).blocker
                == .validationRequired
        )
    }

    @Test func failedValidationCannotSetProgressToOneHundredPercent() {
        var project = makeProject(status: .completed)
        CreationLoopWorkflow.completedValidation(succeeded: false, in: &project)

        let result = CreationLoopWorkflow.completed(in: &project)

        #expect(result.blocker == .validationFailed)
        #expect(project.creationLoop.phase == .awaitingHarnessReview)
        #expect(project.stage != .release)
        #expect(project.progress < 1)
    }

    @Test func verifiedCompletionPreservesRecordedWorkStatuses() {
        var project = makeProject(status: .completed)
        let responseItem = WorkItem(
            title: "AIの提案を確認",
            detail: "続けて",
            status: .needsAttention,
            responseToMessageID: UUID()
        )
        project.workItems.append(responseItem)
        CreationLoopWorkflow.completedValidation(succeeded: true, in: &project)

        let result = CreationLoopWorkflow.completed(in: &project)

        #expect(result.isReady)
        #expect(project.creationLoop.phase == .completed)
        #expect(project.progress == 1)
        #expect(project.workItems.last?.status == .needsAttention)
    }

    @Test func anActiveCoordinatedRunCannotBeDeclaredComplete() {
        var project = makeProject(status: .completed)
        project.runCoordinator = RunCoordinatorState(
            phase: .awaitingReview,
            currentWorkItemID: project.workItems.first?.id,
            attemptedCycleCount: 1
        )
        CreationLoopWorkflow.completedValidation(succeeded: true, in: &project)

        #expect(
            CreationCompletionPolicy.readiness(for: project).blocker
                == .operationInProgress
        )

        project.runCoordinator.phase = .readyForFinalValidation
        project.runCoordinator.currentWorkItemID = nil
        #expect(CreationCompletionPolicy.readiness(for: project).isReady)
    }

    private func makeProject(status: WorkStatus) -> HarnessProject {
        HarnessProject(
            name: "Completion",
            summary: "",
            targets: [.macOS],
            stage: .finish,
            progress: 0.9,
            currentActivity: "確認中",
            workItems: [WorkItem(title: "仕上げる", detail: "", status: status)],
            activity: [],
            creationLoop: CreationLoopState(phase: .awaitingUserDecision)
        )
    }
}
