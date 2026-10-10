import Foundation
import HarnessCore

enum ProductionMultiItemE2EChecks {
    private static let targetPath = "Sources/Greeting/Greeting.swift"

    static func run() async throws {
        let entry = try require(ModelCatalogEntry.recommended.first)
        let identifier = try require(entry.identifier(for: .ollama))
        let fixture = try ProductionMultiItemFixture()
        defer { fixture.remove() }

        let model = ModelSelection(
            identifier: identifier,
            displayName: entry.displayName,
            runtime: .ollama
        )
        let engine = ProductionE2EEngine(model: model)
        var project = fixture.project(model: model)
        var generations: [TimeInterval] = []
        var validations: [ProductionValidationRun] = []
        var restarts: [ProductionRestartSummary] = []
        let startedAt = Date()

        let first = try ProductionE2EEngine.selected(
            RunCoordinatorWorkflow.beginNext(in: &project)
        )
        try expect(first.id == project.workItems[0].id, "First item selection changed")
        generations.append(try await apply(
            "greeting()が「おはよう」を返すようにしてね。他の関数は変えないで。",
            engine: engine,
            project: &project,
            rootPath: fixture.root.path
        ))
        let intendedFailure = try await engine.validate(
            project: &project,
            rootPath: fixture.root.path
        )
        validations.append(.init(purpose: .intendedFailure, report: intendedFailure))
        try expect(
            !intendedFailure.succeeded && project.runCoordinator.phase == .awaitingRepair,
            "First item failure did not stop for repair"
        )

        _ = try ProductionE2EEngine.selected(
            RunCoordinatorWorkflow.resumeCurrent(in: &project)
        )
        generations.append(try await apply(
            "検証で不合格でした。greeting()が正確に「こんにちは」を返すよう直してね。他の関数は変えないで。",
            engine: engine,
            project: &project,
            rootPath: fixture.root.path
        ))
        let firstPass = try await engine.validate(
            project: &project,
            rootPath: fixture.root.path
        )
        validations.append(.init(purpose: .firstItem, report: firstPass))
        try approve(firstPass, in: &project, message: "First repaired item did not pass")

        project = try fixture.restarted(project)
        restarts.append(try restartSummary(
            .afterFirstApproval,
            expected: .readyForNextItem,
            project: project,
            pinnedID: nil
        ))

        try fixture.activateValidation(.farewell)
        let second = try ProductionE2EEngine.selected(
            RunCoordinatorWorkflow.beginNext(in: &project)
        )
        try expect(second.id == project.workItems[1].id, "Second item selection changed")
        generations.append(try await apply(
            "farewell()が正確に「またね」を返すようにしてね。他の関数は変えないで。",
            engine: engine,
            project: &project,
            rootPath: fixture.root.path
        ))
        project = try fixture.restarted(project)
        restarts.append(try restartSummary(
            .beforeSecondValidation,
            expected: .awaitingValidation,
            project: project,
            pinnedID: second.id
        ))
        let secondPass = try await engine.validate(
            project: &project,
            rootPath: fixture.root.path
        )
        validations.append(.init(purpose: .secondItem, report: secondPass))
        try approve(secondPass, in: &project, message: "Second item did not pass")

        try fixture.activateValidation(.welcome)
        let third = try ProductionE2EEngine.selected(
            RunCoordinatorWorkflow.beginNext(in: &project)
        )
        try expect(third.id == project.workItems[2].id, "Third item selection changed")
        RunCoordinatorWorkflow.pause(in: &project)
        project = try fixture.restarted(project)
        restarts.append(try restartSummary(
            .pausedThirdItem,
            expected: .paused,
            project: project,
            pinnedID: third.id
        ))
        let resumed = try ProductionE2EEngine.selected(
            RunCoordinatorWorkflow.resumeCurrent(in: &project)
        )
        try expect(resumed.id == third.id, "Restart resumed a different third item")
        generations.append(try await apply(
            "welcome(_ name: String)が名前を使って「こんにちは、\\(name)さん」を返すようにしてね。他の関数は変えないで。",
            engine: engine,
            project: &project,
            rootPath: fixture.root.path
        ))
        let thirdPass = try await engine.validate(
            project: &project,
            rootPath: fixture.root.path
        )
        validations.append(.init(purpose: .thirdItem, report: thirdPass))
        try approve(thirdPass, in: &project, message: "Third item did not pass")

        try expect(
            RunCoordinatorWorkflow.beginNext(in: &project) == .readyForFinalValidation,
            "Three approved items did not reach final validation"
        )
        let finalPass = try await engine.validate(
            project: &project,
            rootPath: fixture.root.path
        )
        validations.append(.init(purpose: .final, report: finalPass))
        let completion = CreationLoopWorkflow.completed(in: &project)
        try expect(
            finalPass.succeeded && completion.isReady
                && project.progress == 1 && project.stage == .release,
            "Restarted multi-item work did not complete with fresh evidence"
        )

        let report = ProductionMultiItemReport(
            model: identifier,
            totalSeconds: Date().timeIntervalSince(startedAt),
            generationSeconds: generations,
            validations: validations,
            restarts: restarts,
            attemptedCycles: project.runCoordinator.attemptedCycleCount,
            approvedCycles: project.runCoordinator.approvedCycleCount,
            ledgerEvents: project.runCoordinator.records.map(\.event),
            completed: project.progress == 1
        )
        FileHandle.standardOutput.write(try JSONEncoder().encode(report) + Data("\n".utf8))
        print("Multi-item production E2E completed with restart recovery.")
    }

    private static func apply(
        _ instruction: String,
        engine: ProductionE2EEngine,
        project: inout HarnessProject,
        rootPath: String
    ) async throws -> TimeInterval {
        let started = Date()
        try await engine.applyModelEdit(
            instruction: instruction,
            project: &project,
            rootPath: rootPath,
            targetPath: targetPath
        )
        return Date().timeIntervalSince(started)
    }

    private static func approve(
        _ report: ProjectValidationReport,
        in project: inout HarnessProject,
        message: String
    ) throws {
        try expect(
            report.succeeded && project.runCoordinator.phase == .awaitingReview
                && RunCoordinatorWorkflow.approveCurrent(in: &project),
            message
        )
    }

    private static func restartSummary(
        _ point: ProductionRestartPoint,
        expected phase: RunCoordinatorPhase,
        project: HarnessProject,
        pinnedID: UUID?
    ) throws -> ProductionRestartSummary {
        try expect(
            project.runCoordinator.phase == phase
                && project.runCoordinator.currentWorkItemID == pinnedID,
            "Restart did not preserve the expected coordinator checkpoint"
        )
        return ProductionRestartSummary(
            point: point,
            phase: phase,
            itemRemainedPinned: pinnedID != nil
        )
    }
}

private enum ProductionValidationPurpose: String, Encodable {
    case intendedFailure, firstItem, secondItem, thirdItem, final
}

private struct ProductionValidationRun: Encodable {
    let purpose: ProductionValidationPurpose
    let checks: [ValidationSummary]

    init(purpose: ProductionValidationPurpose, report: ProjectValidationReport) {
        self.purpose = purpose
        self.checks = ProductionE2EEngine.summary(report)
    }
}

private enum ProductionRestartPoint: String, Encodable {
    case afterFirstApproval, beforeSecondValidation, pausedThirdItem
}

private struct ProductionRestartSummary: Encodable {
    let point: ProductionRestartPoint
    let phase: RunCoordinatorPhase
    let itemRemainedPinned: Bool
}

private struct ProductionMultiItemReport: Encodable {
    let model: String
    let totalSeconds: TimeInterval
    let generationSeconds: [TimeInterval]
    let validations: [ProductionValidationRun]
    let restarts: [ProductionRestartSummary]
    let attemptedCycles: Int
    let approvedCycles: Int
    let ledgerEvents: [RunCoordinatorEvent]
    let completed: Bool
}
