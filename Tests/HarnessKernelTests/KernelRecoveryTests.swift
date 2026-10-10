import Foundation
import HarnessKernel
import HarnessKernelContracts
import HarnessKernelPersistence
import Testing

struct KernelRecoveryTests {
    @Test func restartPreservesUnresolvedAttemptAndSupportsModelChange() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.engine()
        try await first.record(.planned(fixture.plan))
        let attemptID = UUID()
        try await first.record(.stepStarted(stepID: fixture.plan.steps[0].id, attemptID: attemptID))

        let restarted = try fixture.engine()
        #expect(await restarted.snapshot().activeAttempt?.id == attemptID)
        await #expect(throws: KernelError.unresolvedAttempt) {
            try await restarted.record(.stepStarted(stepID: fixture.plan.steps[0].id, attemptID: UUID()))
        }
        try await restarted.record(.paused(reason: "終了時の実行結果を確認する"))
        await #expect(throws: KernelError.unresolvedAttempt) {
            try await restarted.record(.resumed(modelIdentifier: "replacement-model"))
        }
        try await restarted.record(.stepFinished(attemptID: attemptID, succeeded: false))
        try await restarted.record(.decisionRecorded("外部結果を確認し、未完了のため再試行する"))
        try await restarted.record(.resumed(modelIdentifier: "replacement-model"))
        let recovered = try fixture.engine()
        let state = await recovered.snapshot()
        #expect(state.modelIdentifier == "replacement-model")
        #expect(state.nextStep?.id == fixture.plan.steps[0].id)
        #expect(state.lastDecision != nil)
    }

    @Test func completionRequiresEveryCurrentRequirementAndSurvivesReload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let engine = try fixture.engine()
        try await engine.record(.planned(fixture.plan))
        let attemptID = UUID()
        try await engine.record(.stepStarted(stepID: fixture.plan.steps[0].id, attemptID: attemptID))
        let state = try await engine.record(.stepFinished(attemptID: attemptID, succeeded: true))
        await #expect(throws: KernelError.completionNotVerified) { try await engine.record(.completed) }
        await #expect(throws: KernelError.invalidEvidence) {
            try await engine.record(.verificationRecorded(KernelEvidence(
                requirementID: fixture.plan.requirements[0].id, revision: state.revision - 1,
                passed: true, reportReference: "report/unit.json"
            )))
        }
        for requirement in fixture.plan.requirements {
            try await engine.record(.verificationRecorded(KernelEvidence(
                requirementID: requirement.id, revision: state.revision,
                passed: false, reportReference: "report/\(requirement.kind).json"
            )))
            await #expect(throws: KernelError.completionNotVerified) { try await engine.record(.completed) }
            try await engine.record(.verificationRecorded(KernelEvidence(
                requirementID: requirement.id, revision: state.revision,
                passed: true, reportReference: "report/\(requirement.kind).json"
            )))
        }
        let repair = try await engine.record(.stepReopened(
            stepID: fixture.plan.steps[0].id, reason: "画面の操作で追加の不具合を確認"
        ))
        #expect(repair.evidence.isEmpty)
        #expect(!repair.canComplete)
        let retryID = UUID()
        try await engine.record(.stepStarted(stepID: fixture.plan.steps[0].id, attemptID: retryID))
        let repaired = try await engine.record(.stepFinished(attemptID: retryID, succeeded: true))
        for requirement in fixture.plan.requirements {
            try await engine.record(.verificationRecorded(KernelEvidence(
                requirementID: requirement.id, revision: repaired.revision,
                passed: true, reportReference: "report/repaired-\(requirement.kind).json"
            )))
        }
        try await engine.record(.completed)
        let recovered = try fixture.engine()
        #expect(await recovered.snapshot().phase == .completed)
        await #expect(throws: KernelError.invalidTransition) { try await recovered.record(.completed) }
    }

    @Test func staleWriterCannotOverwriteHistoryOrAdvanceMemory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.engine()
        let stale = try fixture.engine()
        try await first.record(.planned(fixture.plan))
        await #expect(throws: KernelError.journalConflict) { try await stale.record(.planned(fixture.plan)) }
        #expect(await stale.snapshot().sequence == 0)
        #expect(try fixture.journal.read().count == 1)
    }

    @Test(arguments: ["corrupt", "gap", "future-schema", "symlink"])
    func damagedHistoryFailsClosed(damage: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.engine().record(.planned(fixture.plan))
        let file = fixture.directory.appendingPathComponent("00000001.json")
        switch damage {
        case "corrupt": try Data("broken".utf8).write(to: file)
        case "gap":
            try FileManager.default.moveItem(at: file, to: fixture.directory.appendingPathComponent("00000002.json"))
        case "future-schema":
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            object["schemaVersion"] = 999
            try JSONSerialization.data(withJSONObject: object).write(to: file)
        default:
            try FileManager.default.moveItem(at: file, to: fixture.directory.appendingPathComponent(".original"))
            try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: ".original")
        }
        #expect(throws: (any Error).self) { try fixture.engine() }
    }

    @Test func invalidPlanDoesNotCreateAnEvent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let invalid = KernelPlan(userRequest: "制作", modelIdentifier: "model", steps: fixture.plan.steps, requirements: [])
        let engine = try fixture.engine()
        await #expect(throws: KernelError.invalidPlan) { try await engine.record(.planned(invalid)) }
        #expect(try fixture.journal.read().isEmpty)
    }
}

private struct Fixture {
    let directory: URL
    let journal: FileKernelJournal
    let runID = UUID()
    let plan = KernelPlan(
        userRequest: "記録を保存できるようにして", modelIdentifier: "local-model",
        steps: [KernelStep(instruction: "保存処理を実装")],
        requirements: [
            VerificationRequirement(criterion: "保存内容を復元できる", kind: .unit),
            VerificationRequirement(criterion: "再起動しても記録が残る", kind: .heldOut)
        ]
    )

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessKernelTests-\(UUID())")
        journal = try FileKernelJournal(directory: directory)
    }
    func engine() throws -> KernelEngine { try KernelEngine(runID: runID, journal: journal) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
