import Foundation
import HarnessCore

enum RunCoordinatorChecks {
    static func run() throws {
        try checkVerifiedSingleItemFlow()
        try checkRepeatedFailureStop()
        try checkPersistence()
        try checkMultiItemRestartRecovery()
        print("✓ Run coordinator advances one verified item and stops bounded failures")
    }

    private static func checkVerifiedSingleItemFlow() throws {
        let first = WorkItem(title: "最初", detail: "1項目ずつ", status: .pending)
        let second = WorkItem(title: "次", detail: "検証後", status: .pending)
        var project = makeProject(items: [first, second])

        let decision = RunCoordinatorWorkflow.beginNext(in: &project)
        guard case .selected(let selection) = decision else {
            throw CheckFailure(description: "A production item was not selected")
        }
        try expect(
            selection.id == first.id
                && project.runCoordinator.currentWorkItemID == first.id
                && project.runCoordinator.phase == .awaitingChange,
            "The coordinator did not pin exactly one item"
        )
        RunCoordinatorWorkflow.recordedChange(in: &project)
        RunCoordinatorWorkflow.recordedValidation(report(succeeded: true), in: &project)
        try expect(
            project.runCoordinator.phase == .awaitingReview,
            "Successful validation bypassed human review"
        )
        try expect(
            RunCoordinatorWorkflow.approveCurrent(in: &project)
                && project.workItems[0].status == .completed
                && project.workItems[1].status == .pending
                && project.runCoordinator.phase == .readyForNextItem,
            "Approval did not complete only the pinned item"
        )
    }

    private static func checkRepeatedFailureStop() throws {
        var project = makeProject(
            items: [WorkItem(title: "修正", detail: "", status: .pending)]
        )
        _ = RunCoordinatorWorkflow.beginNext(in: &project)
        RunCoordinatorWorkflow.recordedChange(in: &project)
        let failed = report(succeeded: false, output: "private build output")
        RunCoordinatorWorkflow.recordedValidation(failed, in: &project)
        RunCoordinatorWorkflow.recordedValidation(failed, in: &project)

        try expect(
            project.runCoordinator.phase == .blocked
                && project.runCoordinator.stopReason == .repeatedFailure
                && project.runCoordinator.lastFailureFingerprint!.hasPrefix("test:1:")
                && !project.runCoordinator.lastFailureFingerprint!.contains("private"),
            "Matching validation failures did not stop with a metadata-only fingerprint"
        )
    }

    private static func checkPersistence() throws {
        var project = makeProject(
            items: [WorkItem(title: "保存", detail: "", status: .pending)]
        )
        _ = RunCoordinatorWorkflow.beginNext(in: &project)
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(HarnessProject.self, from: data)
        try expect(
            decoded.runCoordinator == project.runCoordinator,
            "Run coordinator state did not survive persistence"
        )
    }

    private static func checkMultiItemRestartRecovery() throws {
        let first = WorkItem(title: "1", detail: "検証前に再起動", status: .pending)
        let second = WorkItem(title: "2", detail: "停止中に再起動", status: .pending)
        var project = makeProject(items: [first, second])

        _ = RunCoordinatorWorkflow.beginNext(in: &project)
        RunCoordinatorWorkflow.recordedChange(in: &project)
        project = try restarted(project)
        try expect(
            project.runCoordinator.phase == .awaitingValidation
                && project.runCoordinator.currentWorkItemID == first.id,
            "Restart lost the pinned item awaiting validation"
        )
        RunCoordinatorWorkflow.recordedValidation(report(succeeded: true), in: &project)
        try expect(RunCoordinatorWorkflow.approveCurrent(in: &project), "First item was not approved")

        project = try restarted(project)
        guard case .selected(let selected) = RunCoordinatorWorkflow.beginNext(in: &project) else {
            throw CheckFailure(description: "Second item was not selected after restart")
        }
        RunCoordinatorWorkflow.pause(in: &project)
        project = try restarted(project)
        guard case .selected(let resumed) = RunCoordinatorWorkflow.resumeCurrent(in: &project) else {
            throw CheckFailure(description: "Paused item was not resumed after restart")
        }
        try expect(
            selected.id == second.id && resumed.id == second.id,
            "Restart changed the pinned second item"
        )
        RunCoordinatorWorkflow.recordedChange(in: &project)
        RunCoordinatorWorkflow.recordedValidation(report(succeeded: true), in: &project)
        try expect(
            RunCoordinatorWorkflow.approveCurrent(in: &project)
                && project.runCoordinator.phase == .readyForFinalValidation
                && project.runCoordinator.attemptedCycleCount == 2
                && project.runCoordinator.approvedCycleCount == 2,
            "Two restarted cycles did not finish with bounded counters"
        )
    }

    private static func restarted(_ project: HarnessProject) throws -> HarnessProject {
        try JSONDecoder().decode(HarnessProject.self, from: JSONEncoder().encode(project))
    }

    private static func makeProject(items: [WorkItem]) -> HarnessProject {
        HarnessProject(
            name: "Run coordinator",
            summary: "",
            targets: [.macOS],
            stage: .build,
            progress: 0.5,
            currentActivity: "待機",
            workItems: items,
            activity: []
        )
    }

    private static func report(
        succeeded: Bool,
        output: String = "passed"
    ) -> ProjectValidationReport {
        ProjectValidationReport(
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            checks: [
                ProjectValidationCheck(
                    kind: .test,
                    succeeded: succeeded,
                    exitCode: succeeded ? 0 : 1,
                    output: output,
                    outputWasTruncated: false,
                    duration: 1
                )
            ]
        )
    }
}
