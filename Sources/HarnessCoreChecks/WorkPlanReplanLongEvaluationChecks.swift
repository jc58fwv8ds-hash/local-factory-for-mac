import Foundation
import HarnessCore

/// Opt-in two-round evaluation with a restart between proposals.
enum WorkPlanReplanLongEvaluationChecks {
    static func run() async throws {
        let engine = try WorkPlanReplanEvaluationEngine.recommended()
        var project = makeProject(model: engine.model)
        let originalCriteria = Dictionary(
            uniqueKeysWithValues: project.workItems.map { ($0.id, ($0.title, $0.detail)) }
        )

        let first = try await engine.propose(
            project: project,
            report: failingReport(kind: .xcodeTest, exitCode: 65),
            analysis: analysis(
                kind: .xcodeTest,
                path: "Tests/VoiceConversationTests.swift",
                line: 42
            )
        )
        try validate(first, project: project)
        try WorkPlanReplanWorkflow.apply(first.proposal, to: &project)
        try validateCriteria(originalCriteria, in: project)
        try expect(project.workItems.count <= 12, "First proposal exceeded total horizon")

        project = try restarted(project)
        let afterFirstCriteria = Dictionary(
            uniqueKeysWithValues: project.workItems.map { ($0.id, ($0.title, $0.detail)) }
        )
        let second = try await engine.propose(
            project: project,
            report: failingReport(kind: .xcodeBuild, exitCode: 70),
            analysis: analysis(
                kind: .xcodeBuild,
                path: "Sources/VoiceConversationSession.swift",
                line: 118
            )
        )
        try validate(second, project: project)
        try WorkPlanReplanWorkflow.apply(second.proposal, to: &project)
        try validateCriteria(afterFirstCriteria, in: project)
        try expect(project.workItems.count <= 12, "Second proposal exceeded total horizon")

        project = try restarted(project)
        try validateCriteria(originalCriteria, in: project)
        try expect(
            project.runCoordinator.currentWorkItemID == project.workItems.first?.id,
            "Pinned item did not survive repeated proposal restart"
        )

        let report = LongEvaluationReport(
            model: engine.model.identifier,
            rounds: [round(first), round(second)],
            finalItemCount: project.workItems.count,
            originalItemsPreserved: true,
            completionCriteriaPreserved: true,
            restartCount: 2
        )
        FileHandle.standardOutput.write(try JSONEncoder().encode(report) + Data("\n".utf8))
        print("Repeated work-plan replan evaluation completed; GUI endurance remains separate.")
    }

    private static func validate(
        _ result: WorkPlanReplanEvaluationResult,
        project: HarnessProject
    ) throws {
        try expect(
            result.proposal.items.first?.existingWorkItemID
                == project.runCoordinator.currentWorkItemID,
            "Generated proposal moved the pinned item"
        )
        try expect(
            result.proposal.items.count <= WorkPlanReplanContext.maximumExistingItems,
            "Generated proposal exceeded total item limit"
        )
        let currentByID = Dictionary(
            uniqueKeysWithValues: project.workItems.map { ($0.id, $0) }
        )
        for proposed in result.proposal.items {
            guard let existingID = proposed.existingWorkItemID,
                  let existing = currentByID[existingID] else { continue }
            try expect(proposed.title == existing.title, "Existing title drifted")
            try expect(proposed.detail == existing.detail, "Existing detail drifted")
        }
    }

    private static func validateCriteria(
        _ criteria: [UUID: (String, String)],
        in project: HarnessProject
    ) throws {
        let currentByID = Dictionary(
            uniqueKeysWithValues: project.workItems.map { ($0.id, $0) }
        )
        for (id, expected) in criteria {
            let item = try require(currentByID[id])
            try expect(item.title == expected.0, "Repeated proposal rewrote an existing title")
            try expect(item.detail == expected.1, "Repeated proposal rewrote completion criteria")
        }
    }

    private static func restarted(_ project: HarnessProject) throws -> HarnessProject {
        try JSONDecoder().decode(
            HarnessProject.self,
            from: JSONEncoder().encode(project)
        )
    }

    private static func makeProject(model: ModelSelection) -> HarnessProject {
        let items = (1...10).map { index in
            WorkItem(
                title: "音声確認\(index)",
                detail: "音声状態\(index)をテストで確認する",
                status: index == 1 ? .active : .pending
            )
        }
        return HarnessProject(
            name: "再計画の長時間合成評価",
            summary: "音声会話の複数失敗を安全に直す",
            targets: [.macOS],
            stage: .test,
            progress: 0.7,
            currentActivity: "検証失敗",
            workItems: items,
            activity: [],
            selectedModel: model,
            creationLoop: CreationLoopState(phase: .awaitingUserDecision),
            runCoordinator: RunCoordinatorState(
                phase: .awaitingRepair,
                currentWorkItemID: items.first?.id,
                attemptedCycleCount: 2
            )
        )
    }

    private static func failingReport(
        kind: ProjectValidationKind,
        exitCode: Int32
    ) -> ProjectValidationReport {
        ProjectValidationReport(
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            checks: [
                ProjectValidationCheck(
                    kind: kind,
                    succeeded: false,
                    exitCode: exitCode,
                    output: "synthetic failure",
                    outputWasTruncated: false,
                    duration: 1
                )
            ]
        )
    }

    private static func analysis(
        kind: ProjectValidationKind,
        path: String,
        line: Int
    ) -> BuildFailureAnalysis {
        BuildFailureAnalysis(
            diagnostics: [
                BuildFailureDiagnostic(
                    validationKind: kind,
                    relativePath: path,
                    line: line,
                    column: 1,
                    message: "raw diagnostic must not enter the replan prompt"
                )
            ],
            unresolvedErrorCount: 0,
            failedKinds: [kind]
        )
    }

    private static func round(
        _ result: WorkPlanReplanEvaluationResult
    ) -> LongEvaluationRound {
        LongEvaluationRound(
            seconds: result.seconds,
            existingItemCount: result.context.items.count,
            availableNewItemCount: result.context.availableNewItemCount,
            proposedNewItemCount: result.proposal.newItemCount,
            uncertaintyCount: result.proposal.uncertainties.count,
            summary: result.proposal.summary
        )
    }
}

private struct LongEvaluationRound: Encodable {
    let seconds: TimeInterval
    let existingItemCount: Int
    let availableNewItemCount: Int
    let proposedNewItemCount: Int
    let uncertaintyCount: Int
    let summary: String
}

private struct LongEvaluationReport: Encodable {
    let model: String
    let rounds: [LongEvaluationRound]
    let finalItemCount: Int
    let originalItemsPreserved: Bool
    let completionCriteriaPreserved: Bool
    let restartCount: Int
}
