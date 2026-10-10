import Foundation
import HarnessCore
import HarnessKernel
import HarnessKernelContracts
import HarnessKernelPersistence
@testable import HarnessExecution
import Testing

struct ValidationArtifactTests {
    @Test(arguments: ["modified", "missing", "symlink", "extra"])
    func archivedEvidenceIsBoundToReceipt(mode: String) async throws {
        let fixture = try EvidenceFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        #expect(try await service.validate(rootPath: fixture.source.path).succeeded)
        let run = try #require(await service.lastRunDirectory)
        #expect(try await ValidationRecoveryService().inspect(runDirectory: run, root: fixture.source) == .verified)
        let receipt = try fixture.receipt(run)
        let events = try FileKernelJournal(directory: run.appendingPathComponent("events")).read()
        let engine = try KernelEngine(runID: receipt.runID, journal: FileKernelJournal(directory: run.appendingPathComponent("events")))
        let state = await engine.snapshot()
        #expect(state.phase == .completed)
        #expect(state.evidence.count == 3)
        if case let .planned(plan) = events[0].payload {
            #expect(plan.requirements.map(\.kind) == [.build, .testExecution, .ui])
        } else { Issue.record("Missing plan") }
        let hash = try #require(state.evidence.values.first?.reportReference.components(separatedBy: "sha256=").last)
        let store = ValidationReceiptStore(runDirectory: run)
        // Original exports can change: archived bytes must remain independent.
        try Data("changed original".utf8).write(to: fixture.assets.appendingPathComponent("summary.json"))
        _ = try store.verified(hash: hash, runID: receipt.runID, root: fixture.source,
                               sourceDigest: receipt.sourceDigest, revision: receipt.revision)
        let image = try #require(receipt.artifacts?.first(where: { $0.kind == .testAttachments })?.files.first)
        let archived = run.appendingPathComponent("evidence/\(image.relativePath)")
        switch mode {
        case "missing": try FileManager.default.removeItem(at: archived)
        case "symlink":
            try FileManager.default.removeItem(at: archived)
            try FileManager.default.createSymbolicLink(at: archived, withDestinationURL: fixture.assets.appendingPathComponent("screens/screen.png"))
        case "extra": try Data("extra".utf8).write(to: run.appendingPathComponent("evidence/extra"))
        default: try Data("changed archive".utf8).write(to: archived)
        }
        #expect(throws: (any Error).self) {
            try store.verified(hash: hash, runID: receipt.runID, root: fixture.source,
                               sourceDigest: receipt.sourceDigest, revision: receipt.revision)
        }
        #expect(try await ValidationRecoveryService().inspect(runDirectory: run, root: fixture.source) == .evidenceUnavailable)
    }

    @Test(arguments: ["zero", "wrong-device", "unit-bundle", "failed-case", "duplicate", "malformed", "no-artifacts", "skipped", "missing-bundle"])
    func optimisticLogDoesNotSatisfyUIAcceptance(mode: String) async throws {
        let fixture = try EvidenceFixture(mode: mode)
        defer { fixture.remove() }
        let service = fixture.service()
        do { #expect(try await !service.validate(rootPath: fixture.source.path).succeeded) }
        catch { /* Unreadable/missing evidence must also fail closed. */ }
        let run = try #require(await service.lastRunDirectory)
        let events = try FileKernelJournal(directory: run.appendingPathComponent("events")).read()
        #expect(!events.contains { $0.payload == .completed })
        #expect(!events.contains { if case .verificationRecorded = $0.payload { true } else { false } })
    }

    @Test func interpretedJSONCannotChangeBeforeArchivingAndLegacyReceiptsStillRead() throws {
        let fixture = try EvidenceFixture()
        defer { fixture.remove() }
        let file = fixture.assets.appendingPathComponent("summary.json")
        let artifact = ProjectValidationArtifact(kind: .testSummary, url: file,
            expectedSHA256: ValidationSourceIdentity.hash(try Data(contentsOf: file)))
        try Data("changed".utf8).write(to: file)
        #expect(throws: (any Error).self) {
            try ValidationArtifactArchive(directory: fixture.root.appendingPathComponent("pinned")).capture([artifact])
        }
        let store = ValidationReceiptStore(runDirectory: fixture.root)
        let receipt = ValidationReceipt(schemaVersion: 1, runID: UUID(), rootPath: fixture.source.path,
            sourceDigest: "legacy", revision: 1, report: fixture.provider.report)
        let hash = try store.save(receipt)
        let verified = try store.verified(hash: hash, runID: receipt.runID, root: fixture.source, sourceDigest: "legacy", revision: 1)
        #expect(verified.artifacts == nil)
    }
}

private struct EvidenceFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessEvidence-\(UUID())").resolvingSymlinksInPath()
    let device = UUID()
    var source: URL { root.appendingPathComponent("source") }
    var assets: URL { root.appendingPathComponent("assets") }
    let provider: EvidenceProvider

    init(mode: String = "passed") throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("source"), withIntermediateDirectories: true)
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
        try Data("let value = 1".utf8).write(to: root.appendingPathComponent("source/Example.swift"))
        let count = mode == "zero" ? 0 : 1
        let summary: [String: Any] = ["result": "Passed", "totalTestCount": count, "passedTests": count,
            "failedTests": 0, "skippedTests": mode == "skipped" ? 1 : 0, "expectedFailures": 0,
            "devicesAndConfigurations": [["device": ["deviceId": mode == "wrong-device" ? UUID().uuidString : device.uuidString,
                "platform": "iOS Simulator"], "passedTests": count, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0]]]
        let node = ["nodeType": "Test Case", "nodeIdentifier": "MemoryTests/relaunch()", "result": mode == "failed-case" ? "Failed" : "Passed"]
        let tree: [String: Any] = ["testNodes": [["nodeType": mode == "unit-bundle" ? "Unit test bundle" : "UI test bundle",
                                                "children": mode == "duplicate" ? [node, node] : [node]]]]
        try JSONSerialization.data(withJSONObject: summary).write(to: assets.appendingPathComponent("summary.json"))
        try (mode == "malformed" ? Data("{".utf8) : JSONSerialization.data(withJSONObject: tree))
            .write(to: assets.appendingPathComponent("tests.json"))
        // Archival tests treat image bytes as opaque; they do not claim visual evaluation.
        try FileManager.default.createDirectory(at: assets.appendingPathComponent("screens"), withIntermediateDirectories: false)
        try Data([137, 80, 78, 71]).write(to: assets.appendingPathComponent("screens/screen.png"))
        try FileManager.default.createDirectory(at: assets.appendingPathComponent("Tests.xcresult"), withIntermediateDirectories: false)
        try Data("fixture result bundle".utf8).write(to: assets.appendingPathComponent("Tests.xcresult/data"))
        var artifacts = mode == "no-artifacts" ? [] : [
            ProjectValidationArtifact(kind: .testSummary, url: assets.appendingPathComponent("summary.json")),
            ProjectValidationArtifact(kind: .testTree, url: assets.appendingPathComponent("tests.json")),
            ProjectValidationArtifact(kind: .testAttachments, url: assets.appendingPathComponent("screens"))
        ]
        if mode != "no-artifacts" && mode != "missing-bundle" {
            artifacts.append(ProjectValidationArtifact(kind: .xcodeResult, url: assets.appendingPathComponent("Tests.xcresult")))
        }
        provider = EvidenceProvider(report: ProjectValidationReport(startedAt: .now, finishedAt: .now, checks: [
            ProjectValidationCheck(kind: .xcodeBuild, succeeded: true, exitCode: 0, output: "Build succeeded", outputWasTruncated: false, duration: 0),
            ProjectValidationCheck(kind: .xcodeTest, succeeded: true, exitCode: 0, output: "Executed 1 test", outputWasTruncated: false, duration: 0)
        ], artifacts: artifacts))
    }
    func service() -> RecordedProjectValidationService {
        RecordedProjectValidationService(provider: provider, directory: root.appendingPathComponent("runs"),
            uiAcceptance: acceptance)
    }
    var acceptance: XcodeUIAcceptance {
        XcodeUIAcceptance(criterion: "保存後再起動できる", deviceID: device, testIdentifiers: ["MemoryTests/relaunch()"])
    }
    func receipt(_ run: URL) throws -> ValidationReceipt {
        try JSONDecoder().decode(ValidationReceipt.self, from: Data(contentsOf: run.appendingPathComponent("validation.json")))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct EvidenceProvider: ProjectValidating {
    let report: ProjectValidationReport
    func support(rootPath: String) async -> ProjectValidationSupport? { .init(system: .xcode) }
    func validate(rootPath: String) async throws -> ProjectValidationReport { report }
}
