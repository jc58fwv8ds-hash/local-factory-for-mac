import Foundation
import HarnessCore
import HarnessKernel
import HarnessKernelContracts
import HarnessKernelPersistence

/// First App-to-Kernel migration: validates a fixed project using the existing Apple adapter.
/// Completion here means command validation only, not product/visual acceptance.
public actor RecordedProjectValidationService: ProjectValidating, ProjectValidationRecovering {
    private let provider: any ProjectValidating
    private let directory: URL
    private let requireTests: Bool
    private let uiAcceptance: XcodeUIAcceptance?
    private var activeRoots = Set<String>()
    public private(set) var lastRunDirectory: URL?

    public init(
        provider: any ProjectValidating = LocalProjectValidationService(),
        directory: URL? = nil, requireTests: Bool = false, uiAcceptance: XcodeUIAcceptance? = nil
    ) {
        self.provider = provider
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harness/KernelValidation", isDirectory: true)
        self.requireTests = requireTests || uiAcceptance != nil
        self.uiAcceptance = uiAcceptance
    }

    public func support(rootPath: String) async -> ProjectValidationSupport? {
        await provider.support(rootPath: rootPath)
    }

    public func recoverValidation(rootPath: String) async throws -> ValidationRecoveryStatus? {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        if activeRoots.contains(root.path) { return .unresolved }
        let index = RootRunIndex(directory: directory)
        // No directory means no prior validation; do not create one just for inspection.
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let lease: LocalExecutionLease
        do { lease = try ValidationExecutionLease.acquire(directory: directory, root: root) }
        catch LocalExecutionLeaseError.inUse { return .unresolved }
        catch { return .journalUnavailable }
        defer { withExtendedLifetime(lease) {} }
        let id: UUID
        do {
            guard let stored = try index.load(root: root) else { return nil }
            id = stored
        } catch { return .journalUnavailable }
        let result = try await ValidationRecoveryService().inspect(
            runDirectory: directory.appendingPathComponent(id.uuidString), root: root
        )
        guard try index.load(root: root) == id, !activeRoots.contains(root.path) else { return .unresolved }
        return result
    }

    public func validate(rootPath: String) async throws -> ProjectValidationReport {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        guard activeRoots.insert(root.path).inserted else { throw RecordedValidationError.alreadyRunning }
        defer { activeRoots.remove(root.path) }
        try Task.checkCancellation()
        guard uiAcceptance?.isValid != false else { throw RecordedValidationError.invalidReceipt }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let lease: LocalExecutionLease
        do { lease = try ValidationExecutionLease.acquire(directory: directory, root: root) }
        catch LocalExecutionLeaseError.inUse { throw RecordedValidationError.alreadyRunning }
        defer { withExtendedLifetime(lease) {} }
        let sourceDigest = try await ValidationSourceIdentity.digest(root: root)
        let runID = UUID()
        let runDirectory = directory.appendingPathComponent(runID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let journal = try FileKernelJournal(directory: runDirectory.appendingPathComponent("events"))
        let engine = try KernelEngine(runID: runID, journal: journal)
        lastRunDirectory = runDirectory
        let step = KernelStep(instruction: "現在のソースをビルドし、用意されたテストを実行する")
        var requirements = [VerificationRequirement(criterion: "ビルドが成功する", kind: .build)]
        if requireTests {
            requirements.append(VerificationRequirement(criterion: "1件以上のテストが実行され、成功する", kind: .testExecution))
        }
        if let uiAcceptance {
            requirements.append(VerificationRequirement(criterion: uiAcceptance.criterion, kind: .ui))
        }
        try await engine.record(.planned(KernelPlan(
            userRequest: "現在のプロジェクトのビルドとテストを確認する",
            modelIdentifier: "deterministic-validation-adapter", steps: [step], requirements: requirements
        )))
        try await engine.record(.decisionRecorded("対象: \(root.path) / source SHA-256: \(sourceDigest)"))
        // Persist why this path uses tools, before any build/test process starts.
        // External-model readiness is deliberately irrelevant to deterministic validation.
        let routing = KernelRoutingPolicy.decide(work: .deterministic, localCompatible: false,
            subscriptionDispatchVerified: false, solAvailable: false, astraAvailable: false)
        let routingReceipt = try await engine.recordRoutingDecision(routing)
        try RootRunIndex(directory: directory).save(runID: runID, root: root)
        let attemptID = UUID()
        let started = try await engine.startDeterministicStep(using: routingReceipt, attemptID: attemptID)
        do {
            let raw = try await provider.validate(rootPath: root.path)
            try Task.checkCancellation()
            var report = ValidationResultPolicy.normalize(raw, requireTests: requireTests)
            guard try await ValidationSourceIdentity.digest(root: root) == sourceDigest else {
                throw RecordedValidationError.sourceChanged
            }
            let archive = ValidationArtifactArchive(directory: runDirectory.appendingPathComponent("evidence"))
            let records = try archive.capture(report.artifacts ?? [])
            if let uiAcceptance, try !archive.satisfies(uiAcceptance, records: records) {
                let failed = ProjectValidationCheck(kind: .xcodeTest, succeeded: false, exitCode: 1,
                    output: "[Harness] 指定した画面操作の合格をXcodeの検証結果から確認できませんでした。",
                    outputWasTruncated: false, duration: 0)
                report = ProjectValidationReport(startedAt: report.startedAt, finishedAt: report.finishedAt,
                                                 checks: report.checks + [failed], artifacts: report.artifacts)
            }
            let receipt = ValidationReceipt(schemaVersion: 2, runID: runID, rootPath: root.path,
                sourceDigest: sourceDigest, revision: started.revision, report: report,
                artifacts: records, uiAcceptance: uiAcceptance)
            let store = ValidationReceiptStore(runDirectory: runDirectory)
            let hash = try store.save(receipt)
            let verified = try store.verified(hash: hash, runID: runID, root: root,
                                              sourceDigest: sourceDigest, revision: started.revision)
            try Task.checkCancellation()
            try await engine.record(.stepFinished(attemptID: attemptID, succeeded: verified.report.succeeded))
            try await engine.record(.decisionRecorded("検証報告: validation.json / SHA-256: \(hash)"))
            if verified.report.succeeded {
                for requirement in requirements {
                    try await engine.record(.verificationRecorded(KernelEvidence(
                        requirementID: requirement.id, revision: started.revision, passed: true,
                        reportReference: "validation.json#sha256=\(hash)"
                    )))
                }
                try await engine.record(.completed)
            }
            return verified.report
        } catch {
            // Keep the attempt unresolved: callers must inspect the external result before resuming it.
            _ = try? await engine.record(.paused(reason: "検証が中断されたか、対象と記録を確認できませんでした"))
            throw error
        }
    }
}
