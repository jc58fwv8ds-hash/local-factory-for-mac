import Foundation
import HarnessCore
import HarnessKernel
import HarnessKernelContracts
import HarnessKernelPersistence
@testable import HarnessExecution
import Testing

struct RecordedValidationTests {
    @Test func deterministicRouteIsRecordedBeforeValidationStarts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service(provider: Validator())
        #expect(try await service.validate(rootPath: fixture.source.path).succeeded)
        let run = try #require(await service.lastRunDirectory)
        let events = try FileKernelJournal(directory: run.appendingPathComponent("events")).read()
        let routed = try events.compactMap { event -> (Int, KernelRoutingRecord)? in
            guard let receipt = try KernelRoutingRecord.decode(event.payload) else { return nil }
            return (event.sequence, receipt)
        }
        #expect(routed.count == 1)
        let receipt = try #require(routed.first)
        #expect(receipt.1.decision.route == .tools)
        #expect(!receipt.1.decision.independentReviewRequired)
        let start = try #require(events.first { if case .stepStarted = $0.payload { return true }; return false })
        #expect(receipt.0 < start.sequence)
        if case .stepStarted(let stepID, _) = start.payload { #expect(receipt.1.stepID == stepID) }
        #expect(try await service.recoverValidation(rootPath: fixture.source.path) == .verified)
    }

    @Test(arguments: ["pass", "reject", "insufficient", "stale", "changed"])
    func reviewCannotOverrideMissingOrChangedEvidence(mode: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let contract = try await RepairAcceptanceContract.capture(root: fixture.source, paths: ["Example.swift"])
        let service = fixture.service(provider: Validator())
        _ = try await service.validate(rootPath: fixture.source.path)
        let run = try #require(await service.lastRunDirectory)
        let reviewer = FixtureReviewer(mode: mode, root: fixture.source)
        if mode == "pass" {
            let review = try await RepairReviewGate().evaluate(contract: contract, root: fixture.source,
                validationRun: run, target: "Example.swift", request: "保存して", reviewer: reviewer)
            #expect(review.correctness == .pass)
        } else if mode == "stale" || mode == "changed" {
            do {
                _ = try await RepairReviewGate().evaluate(contract: contract, root: fixture.source,
                    validationRun: run, target: "Example.swift", request: "保存して", reviewer: reviewer)
                Issue.record("Changed evidence must not produce actionable feedback")
            } catch RepairReviewError.evidenceChanged {} catch { Issue.record("Unexpected error: \(error)") }
        } else {
            await #expect(throws: (any Error).self) {
                try await RepairReviewGate().evaluate(contract: contract, root: fixture.source,
                    validationRun: run, target: "Example.swift", request: "保存して", reviewer: reviewer)
            }
        }
    }
    @Test(arguments: [false, true])
    func acceptanceRejectsProtectedChangesEvenWithFreshPassingEvidence(changed: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let contract = try await RepairAcceptanceContract.capture(root: fixture.source, paths: ["Example.swift"])
        if changed {
            try Data("let value = 2".utf8).write(to: fixture.source.appendingPathComponent("Example.swift"))
        }
        let service = fixture.service(provider: Validator())
        #expect(try await service.validate(rootPath: fixture.source.path).succeeded)
        let run = try #require(await service.lastRunDirectory)
        #expect(try await ValidationRecoveryService().inspect(runDirectory: run, root: fixture.source) == .verified)
        if changed {
            await #expect(throws: RepairAcceptanceError.protectedFilesChanged) {
                try await RepairAcceptanceEvaluator().evaluate(contract: contract, root: fixture.source, validationRun: run)
            }
        } else {
            let reference = try await RepairAcceptanceEvaluator().evaluate(contract: contract, root: fixture.source, validationRun: run)
            #expect(reference.hasPrefix("validation.json#sha256="))
        }
    }

    @Test func invalidIndexDoesNotFallBackToAnOlderSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service(provider: Validator())
        #expect(try await service.recoverValidation(rootPath: fixture.source.path) == nil)
        _ = try await service.validate(rootPath: fixture.source.path)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.root.appendingPathComponent("runs"), includingPropertiesForKeys: nil)
        let index = try #require(files.first { $0.pathExtension == "run" })
        try Data("../outside".utf8).write(to: index)
        #expect(try await fixture.service(provider: Validator()).recoverValidation(rootPath: fixture.source.path) == .journalUnavailable)
        try FileManager.default.removeItem(at: index)
        #expect(try await fixture.service(provider: Validator()).recoverValidation(rootPath: fixture.source.path) == nil)
    }

    @Test(arguments: ["healthy", "changed", "missing-report", "corrupt-history", "unresolved"])
    func recoveryChecksCurrentEvidenceWithoutReexecuting(mode: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service(provider: Validator(mode: mode == "unresolved" ? "cancelled" : "success"))
        if mode == "unresolved" {
            await #expect(throws: CancellationError.self) { try await service.validate(rootPath: fixture.source.path) }
        } else { #expect(try await service.validate(rootPath: fixture.source.path).succeeded) }
        let run = try #require(await service.lastRunDirectory)
        let eventURL = run.appendingPathComponent("events/00000001.json")
        var expected = ValidationRecoveryStatus.verified
        switch mode {
        case "changed":
            try Data("let value = 99".utf8).write(to: fixture.source.appendingPathComponent("Example.swift"))
            expected = .sourceChanged
        case "missing-report":
            try FileManager.default.removeItem(at: run.appendingPathComponent("validation.json"))
            expected = .evidenceUnavailable
        case "corrupt-history":
            try Data("broken".utf8).write(to: eventURL)
            expected = .journalUnavailable
        case "unresolved": expected = .unresolved
        default: break
        }
        let before = try Data(contentsOf: eventURL)
        #expect(try await ValidationRecoveryService().inspect(runDirectory: run, root: fixture.source) == expected)
        if expected == .verified {
            let reference = try await VerifiedValidationReference.read(runDirectory: run, root: fixture.source)
            #expect(reference.hasPrefix("validation.json#sha256="))
        } else {
            await #expect(throws: KernelError.invalidEvidence) {
                try await VerifiedValidationReference.read(runDirectory: run, root: fixture.source)
            }
        }
        let reopened = fixture.service(provider: Validator())
        #expect(try await reopened.recoverValidation(rootPath: fixture.source.path) == expected)
        #expect(try Data(contentsOf: eventURL) == before)
        let absent = fixture.root.appendingPathComponent("absent-run")
        #expect(try await ValidationRecoveryService().inspect(runDirectory: absent, root: fixture.source) == .journalUnavailable)
        #expect(!FileManager.default.fileExists(atPath: absent.path))
    }

    @Test func gitIdentityIncludesChangesAndDeletionsButIgnoresBuildOutputs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = BoundedCommandRunner(timeout: .seconds(5))
        for arguments in [["init", "-q"], ["add", "Example.swift"]] {
            let result = try await runner.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", fixture.source.path] + arguments)
            #expect(result.exitCode == 0)
        }
        try Data("cache/\n".utf8).write(to: fixture.source.appendingPathComponent(".gitignore"))
        let original = try await ValidationSourceIdentity.digest(root: fixture.source)
        let cache = fixture.source.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        try Data("generated".utf8).write(to: cache.appendingPathComponent("artifact"))
        #expect(try await ValidationSourceIdentity.digest(root: fixture.source) == original)
        let added = fixture.source.appendingPathComponent(" name with spaces.swift")
        try Data("let other = 2".utf8).write(to: added)
        let changed = try await ValidationSourceIdentity.digest(root: fixture.source)
        #expect(changed != original)
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("Example.swift"))
        #expect(try await ValidationSourceIdentity.digest(root: fixture.source) != changed)
    }

    @Test func successfulCommandsCreateSourceBoundEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service(provider: Validator())
        #expect(try await service.validate(rootPath: fixture.source.path).succeeded)
        let run = try #require(await service.lastRunDirectory)
        let receipt = try JSONDecoder().decode(ValidationReceipt.self, from: Data(contentsOf: run.appendingPathComponent("validation.json")))
        let engine = try KernelEngine(runID: receipt.runID,
                                      journal: FileKernelJournal(directory: run.appendingPathComponent("events")))
        let state = await engine.snapshot()
        #expect(state.phase == .completed)
        #expect(state.evidence.count == 2)
        #expect(receipt.sourceDigest == (try await ValidationSourceIdentity.digest(root: fixture.source)))

        let store = ValidationReceiptStore(runDirectory: run)
        let hash = try #require(state.evidence.values.first?.reportReference.components(separatedBy: "sha256=").last)
        try Data("changed".utf8).write(to: run.appendingPathComponent("validation.json"))
        #expect(throws: (any Error).self) {
            try store.verified(hash: hash, runID: receipt.runID, root: fixture.source,
                               sourceDigest: receipt.sourceDigest, revision: receipt.revision)
        }
    }

    @Test(arguments: ["zero-tests", "missing-tests", "failed-build", "exit-mismatch"])
    func unsuccessfulValidationNeverCompletes(mode: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service(provider: Validator(mode: mode))
        #expect(try await !service.validate(rootPath: fixture.source.path).succeeded)
        let run = try #require(await service.lastRunDirectory)
        let events = try FileKernelJournal(directory: run.appendingPathComponent("events")).read()
        #expect(!events.contains { $0.payload == .completed })
        #expect(!events.contains { if case .verificationRecorded = $0.payload { true } else { false } })
    }

    @Test(arguments: ["changed-source", "cancelled"])
    func uncertainValidationLeavesAnUnresolvedAttempt(mode: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service(provider: Validator(mode: mode))
        await #expect(throws: (any Error).self) { try await service.validate(rootPath: fixture.source.path) }
        let run = try #require(await service.lastRunDirectory)
        let journal = try FileKernelJournal(directory: run.appendingPathComponent("events"))
        let runID = try #require(journal.read().first?.runID)
        let engine = try KernelEngine(runID: runID, journal: journal)
        let state = await engine.snapshot()
        #expect(state.phase == .paused)
        #expect(state.activeAttempt != nil)
        #expect(!state.canComplete)
    }
}

private struct FixtureReviewer: RepairReviewing {
    let mode: String
    let root: URL
    func review(_ input: RepairReviewInput) async throws -> RepairReview {
        if mode == "changed" {
            try Data("let value = 3".utf8).write(to: root.appendingPathComponent("Example.swift"))
        }
        return RepairReview(sourceDigest: mode == "stale" ? "outdated" : input.sourceDigest,
            correctness: mode == "reject" ? .changesRequired : mode == "insufficient" ? .insufficientEvidence : .pass,
            maintainability: .pass, explanation: "固定試験の評価理由")
    }
}

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessRecordedValidation-\(UUID())")
    var source: URL { root.appendingPathComponent("source") }
    init() throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("let value = 1".utf8).write(to: source.appendingPathComponent("Example.swift"))
    }
    func service(provider: any ProjectValidating) -> RecordedProjectValidationService {
        RecordedProjectValidationService(provider: provider, directory: root.appendingPathComponent("runs"), requireTests: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct Validator: ProjectValidating {
    var mode = "success"
    func support(rootPath: String) async -> ProjectValidationSupport? { ProjectValidationSupport(system: .swiftPackage) }
    func validate(rootPath: String) async throws -> ProjectValidationReport {
        if mode == "cancelled" { throw CancellationError() }
        if mode == "changed-source" {
            try Data("let value = 2".utf8).write(to: URL(fileURLWithPath: rootPath).appendingPathComponent("Example.swift"))
        }
        var checks = [ProjectValidationCheck(
            kind: .build, succeeded: mode != "failed-build", exitCode: mode == "exit-mismatch" ? 1 : 0,
            output: "Build complete", outputWasTruncated: false, duration: 0
        )]
        if mode != "missing-tests" {
            checks.append(ProjectValidationCheck(kind: .test, succeeded: true, exitCode: 0,
                output: mode == "zero-tests" ? "Test run with 0 tests passed" : "Test run with 4 tests passed",
                outputWasTruncated: false, duration: 0))
        }
        return ProjectValidationReport(startedAt: .now, finishedAt: .now, checks: checks)
    }
}
