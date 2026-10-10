import Foundation
import HarnessCore
import Testing

struct RunCoordinatorTests {
    @Test func selectsOneProductionItemAndKeepsItPinned() throws {
        let active = WorkItem(title: "画面を整える", detail: "カードを追加", status: .active)
        let pending = WorkItem(title: "保存を確認", detail: "再起動する", status: .pending)
        let response = WorkItem(
            title: "AIの返答",
            detail: "制作項目ではない",
            status: .needsAttention,
            responseToMessageID: UUID()
        )
        var project = makeProject(items: [response, pending, active])
        project.creationLoop.lastValidationSucceeded = true

        let decision = RunCoordinatorWorkflow.beginNext(in: &project)
        let selection = try #require(decision.selection)

        #expect(selection.id == active.id)
        #expect(selection.instruction.contains("カードを追加"))
        #expect(project.runCoordinator.currentWorkItemID == active.id)
        #expect(project.runCoordinator.phase == .awaitingChange)
        #expect(project.runCoordinator.attemptedCycleCount == 1)
        #expect(project.runCoordinator.cycleCountSinceConfirmation == 1)
        #expect(project.creationLoop.lastValidationSucceeded == nil)
        #expect(project.workItems.first?.id == response.id)

        #expect(
            RunCoordinatorWorkflow.beginNext(in: &project)
                == .stopped(.operationInProgress)
        )
        #expect(project.runCoordinator.attemptedCycleCount == 1)
    }

    @Test func successfulValidationRequiresApprovalBeforeMovingOn() throws {
        let first = WorkItem(title: "最初", detail: "A", status: .pending)
        let second = WorkItem(title: "次", detail: "B", status: .pending)
        var project = makeProject(items: [first, second])
        _ = RunCoordinatorWorkflow.beginNext(in: &project)

        #expect(!RunCoordinatorWorkflow.approveCurrent(in: &project))
        RunCoordinatorWorkflow.recordedChange(in: &project)
        #expect(project.runCoordinator.phase == .awaitingValidation)
        #expect(
            RunCoordinatorWorkflow.beginNext(in: &project)
                == .stopped(.validationRequired)
        )

        RunCoordinatorWorkflow.recordedValidation(passingReport(), in: &project)
        #expect(project.runCoordinator.phase == .awaitingReview)
        #expect(
            RunCoordinatorWorkflow.beginNext(in: &project)
                == .stopped(.reviewRequired)
        )
        #expect(RunCoordinatorWorkflow.approveCurrent(in: &project))
        #expect(project.workItems.first?.status == .completed)
        #expect(project.workItems.last?.status == .pending)
        #expect(project.runCoordinator.phase == .readyForNextItem)
        #expect(project.runCoordinator.currentWorkItemID == nil)
        #expect(project.runCoordinator.approvedCycleCount == 1)
        #expect(project.creationLoop.lastValidationSucceeded == nil)

        let next = try #require(RunCoordinatorWorkflow.beginNext(in: &project).selection)
        #expect(next.id == second.id)
    }

    @Test func twoMatchingFailuresStopWithoutPersistingBuildOutput() {
        var project = makeProject(
            items: [WorkItem(title: "直す", detail: "失敗を解消", status: .pending)]
        )
        _ = RunCoordinatorWorkflow.beginNext(in: &project)
        RunCoordinatorWorkflow.recordedChange(in: &project)
        let failure = failingReport(
            kind: .build,
            exitCode: 1,
            output: "Sources/App.swift:1:1: error: 秘密のパスと長いログ"
        )

        RunCoordinatorWorkflow.recordedValidation(
            failure,
            analysis: sourceAnalysis(),
            in: &project
        )
        #expect(project.runCoordinator.phase == .awaitingRepair)
        #expect(project.runCoordinator.consecutiveMatchingFailures == 1)
        #expect(project.runCoordinator.lastFailureFingerprint!.hasPrefix("build:1:"))

        RunCoordinatorWorkflow.recordedValidation(
            failure,
            analysis: sourceAnalysis(),
            in: &project
        )
        #expect(project.runCoordinator.phase == .blocked)
        #expect(project.runCoordinator.stopReason == .repeatedFailure)
        #expect(project.runCoordinator.consecutiveMatchingFailures == 2)
        #expect(!project.runCoordinator.lastFailureFingerprint!.contains("秘密"))
        #expect(project.runCoordinator.records.suffix(2).map(\.event)
            == [.validationFailed, .blocked])
    }

    @Test func differentBuildOutputIsNotTreatedAsTheSameFailure() {
        var project = makeProject(
            items: [WorkItem(title: "直す", detail: "", status: .pending)]
        )
        _ = RunCoordinatorWorkflow.beginNext(in: &project)
        RunCoordinatorWorkflow.recordedChange(in: &project)
        RunCoordinatorWorkflow.recordedValidation(
            failingReport(kind: .build, exitCode: 1, output: "Sources/App.swift:1:1: error: A"),
            analysis: sourceAnalysis(),
            in: &project
        )
        RunCoordinatorWorkflow.recordedValidation(
            failingReport(kind: .build, exitCode: 1, output: "Sources/App.swift:1:1: error: B"),
            analysis: sourceAnalysis(),
            in: &project
        )

        #expect(project.runCoordinator.phase == .awaitingRepair)
        #expect(project.runCoordinator.consecutiveMatchingFailures == 1)
    }

    @Test func anExternalSourceChangeExpiresReviewAndValidationEvidence() {
        var project = makeProject(
            items: [WorkItem(title: "確認", detail: "", status: .active)],
            coordinator: RunCoordinatorState(
                phase: .awaitingReview,
                currentWorkItemID: nil,
                attemptedCycleCount: 1
            )
        )
        project.runCoordinator.currentWorkItemID = project.workItems[0].id
        project.creationLoop.lastValidationSucceeded = true

        RunCoordinatorWorkflow.observedSourceChange(in: &project)

        #expect(project.runCoordinator.phase == .awaitingValidation)
        #expect(project.runCoordinator.records.last?.event == .sourceChanged)
        #expect(project.creationLoop.lastValidationSucceeded == nil)
    }

    @Test func deletingTheCurrentItemCanRecoverAfterUserConfirmation() throws {
        let removed = WorkItem(title: "削除対象", detail: "", status: .pending)
        let remaining = WorkItem(title: "残り", detail: "", status: .pending)
        var project = makeProject(items: [removed, remaining])
        _ = RunCoordinatorWorkflow.beginNext(in: &project)
        try ProjectWorkPlanWorkflow.remove(removed.id, from: &project)
        #expect(project.runCoordinator.phase == .blocked)

        let resumed = try #require(
            RunCoordinatorWorkflow.resumeCurrent(in: &project).selection
        )

        #expect(resumed.id == remaining.id)
        #expect(project.runCoordinator.phase == .awaitingChange)
    }

    @Test func aConfirmedCycleLimitCanContinueWithTheNextItem() throws {
        let first = WorkItem(title: "1", detail: "", status: .pending)
        let second = WorkItem(title: "2", detail: "", status: .pending)
        var project = makeProject(
            items: [first, second],
            coordinator: RunCoordinatorState(maximumCycles: 1)
        )
        _ = RunCoordinatorWorkflow.beginNext(in: &project)
        RunCoordinatorWorkflow.recordedChange(in: &project)
        RunCoordinatorWorkflow.recordedValidation(passingReport(), in: &project)
        #expect(RunCoordinatorWorkflow.approveCurrent(in: &project))

        #expect(
            RunCoordinatorWorkflow.beginNext(in: &project)
                == .stopped(.iterationLimit)
        )
        #expect(project.runCoordinator.phase == .paused)
        #expect(project.runCoordinator.currentWorkItemID == nil)

        let resumed = try #require(
            RunCoordinatorWorkflow.resumeCurrent(in: &project).selection
        )
        #expect(resumed.id == second.id)
        #expect(project.runCoordinator.attemptedCycleCount == 2)
        #expect(project.runCoordinator.cycleCountSinceConfirmation == 1)
        #expect(project.runCoordinator.approvedCycleCount == 1)
    }

    @Test func verifiedReviewSurvivesRestartWithoutRepeatingTheCycle() throws {
        var project = makeProject(
            items: [WorkItem(title: "確認", detail: "再起動後に承認", status: .pending)]
        )
        _ = RunCoordinatorWorkflow.beginNext(in: &project)
        RunCoordinatorWorkflow.recordedChange(in: &project)
        RunCoordinatorWorkflow.recordedValidation(passingReport(), in: &project)

        var restored = try JSONDecoder().decode(
            HarnessProject.self,
            from: JSONEncoder().encode(project)
        )

        #expect(restored.runCoordinator.phase == .awaitingReview)
        #expect(restored.runCoordinator.attemptedCycleCount == 1)
        #expect(RunCoordinatorWorkflow.approveCurrent(in: &restored))
        #expect(restored.runCoordinator.approvedCycleCount == 1)
    }

    @Test func inconsistentReviewEvidenceFallsBackToRevalidationAfterRestart() throws {
        let item = WorkItem(title: "不整合", detail: "検証証拠なし", status: .active)
        let project = makeProject(
            items: [item],
            coordinator: RunCoordinatorState(
                phase: .awaitingReview,
                currentWorkItemID: item.id,
                attemptedCycleCount: 1
            )
        )

        let restored = try JSONDecoder().decode(
            HarnessProject.self,
            from: JSONEncoder().encode(project)
        )

        #expect(restored.runCoordinator.phase == .awaitingValidation)
        #expect(restored.runCoordinator.currentWorkItemID == item.id)
        #expect(restored.creationLoop.lastValidationSucceeded == nil)
    }

    @Test func missingPinnedItemBlocksSafelyAfterRestart() throws {
        let project = makeProject(
            items: [WorkItem(title: "残り", detail: "別項目", status: .pending)],
            coordinator: RunCoordinatorState(
                phase: .awaitingValidation,
                currentWorkItemID: UUID(),
                attemptedCycleCount: 1
            )
        )

        let restored = try JSONDecoder().decode(
            HarnessProject.self,
            from: JSONEncoder().encode(project)
        )

        #expect(restored.runCoordinator.phase == .blocked)
        #expect(restored.runCoordinator.stopReason == .workItemUnavailable)
        #expect(restored.runCoordinator.approvedCycleCount == 0)
    }

    @Test func oldProjectsDecodeWithAnInactiveCoordinator() throws {
        let project = makeProject(
            items: [WorkItem(title: "移行", detail: "", status: .pending)]
        )
        let encoded = try JSONEncoder().encode(project)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "runCoordinator")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(HarnessProject.self, from: legacyData)

        #expect(decoded.runCoordinator.phase == .inactive)
        #expect(decoded.runCoordinator.maximumCycles == RunCoordinatorState.defaultMaximumCycles)
        #expect(decoded.runCoordinator.records.isEmpty)
    }

    private func makeProject(
        items: [WorkItem],
        coordinator: RunCoordinatorState = RunCoordinatorState()
    ) -> HarnessProject {
        HarnessProject(
            name: "連続制作テスト",
            summary: "",
            targets: [.macOS],
            stage: .build,
            progress: 0.5,
            currentActivity: "待機中",
            workItems: items,
            activity: [],
            creationLoop: CreationLoopState(phase: .awaitingUserDecision),
            runCoordinator: coordinator
        )
    }

    private func passingReport() -> ProjectValidationReport {
        report(kind: .test, succeeded: true, exitCode: 0, output: "passed")
    }

    private func failingReport(
        kind: ProjectValidationKind,
        exitCode: Int32,
        output: String
    ) -> ProjectValidationReport {
        report(kind: kind, succeeded: false, exitCode: exitCode, output: output)
    }

    private func sourceAnalysis() -> BuildFailureAnalysis {
        BuildFailureAnalysis(
            diagnostics: [BuildFailureDiagnostic(
                validationKind: .build,
                relativePath: "Sources/App.swift",
                line: 1,
                column: 1,
                message: "source failure"
            )],
            unresolvedErrorCount: 0,
            failedKinds: [.build]
        )
    }

    private func report(
        kind: ProjectValidationKind,
        succeeded: Bool,
        exitCode: Int32,
        output: String
    ) -> ProjectValidationReport {
        ProjectValidationReport(
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            checks: [
                ProjectValidationCheck(
                    kind: kind,
                    succeeded: succeeded,
                    exitCode: exitCode,
                    output: output,
                    outputWasTruncated: false,
                    duration: 1
                )
            ]
        )
    }
}

private extension RunCoordinatorDecision {
    var selection: RunCoordinatorWorkSelection? {
        guard case .selected(let selection) = self else { return nil }
        return selection
    }
}
