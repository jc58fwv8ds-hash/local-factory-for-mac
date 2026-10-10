import Foundation
import HarnessCore
import HarnessExecution
import Testing
@testable import HarnessApp

@MainActor
struct ValidationRecoverySessionTests {
    @Test(arguments: [ValidationRecoveryStatus.unresolved, .journalUnavailable, .evidenceUnavailable])
    func clearingPresentationDoesNotBypassAutomaticStartGuard(status: ValidationRecoveryStatus) async {
        let provider = RecoveryProvider(status: status)
        let session = ProjectValidationSession(rootPath: "/unused", provider: provider)
        await session.detectSupport()
        session.clearResult()
        var announced = false
        session.startAutomatically(onStart: { announced = true }, onComplete: { _ in Issue.record("Unexpected execution") })
        #expect(!announced)
        #expect(!session.isRunning)
        #expect(session.recoveryStatus == status)
        #expect(await provider.executions == 0)
    }

    @Test(arguments: [ValidationRecoveryStatus.verified, .sourceChanged, .unresolved])
    func reopeningOnlyInspectsAndDoesNotRestoreAnOldSuccessReport(status: ValidationRecoveryStatus) async {
        let provider = RecoveryProvider(status: status)
        let session = ProjectValidationSession(rootPath: "/unused", provider: provider)
        await session.detectSupport()
        #expect(session.recoveryStatus == status)
        #expect(session.report == nil)
        #expect(!session.isRunning)
        #expect(session.canAutomaticallyStart == (status != .unresolved))
        #expect(await provider.executions == 0)
    }

    @Test func lateRecoveryCannotReplaceClearedState() async {
        let provider = DelayedRecoveryProvider()
        let session = ProjectValidationSession(rootPath: "/unused", provider: provider)
        let detection = Task { await session.detectSupport() }
        await provider.waitUntilRequested()
        #expect(!session.canAutomaticallyStart)
        session.startAutomatically(onStart: { Issue.record("Started before recovery") }, onComplete: { _ in })
        session.clearResult()
        await provider.finish()
        await detection.value
        #expect(session.recoveryStatus == nil)
        #expect(session.report == nil)
        #expect(!session.canAutomaticallyStart)
    }
}

private actor RecoveryProvider: ProjectValidating, ProjectValidationRecovering {
    let status: ValidationRecoveryStatus
    var executions = 0
    init(status: ValidationRecoveryStatus) { self.status = status }
    func support(rootPath: String) async -> ProjectValidationSupport? { .init(system: .swiftPackage) }
    func recoverValidation(rootPath: String) async throws -> ValidationRecoveryStatus? { status }
    func validate(rootPath: String) async throws -> ProjectValidationReport {
        executions += 1
        return .init(startedAt: .now, finishedAt: .now, checks: [])
    }
}

private actor DelayedRecoveryProvider: ProjectValidating, ProjectValidationRecovering {
    private var pending: CheckedContinuation<ValidationRecoveryStatus?, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func support(rootPath: String) async -> ProjectValidationSupport? { .init(system: .swiftPackage) }
    func recoverValidation(rootPath: String) async throws -> ValidationRecoveryStatus? {
        await withCheckedContinuation {
            pending = $0
            waiter?.resume()
            waiter = nil
        }
    }
    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { pending?.resume(returning: .verified); pending = nil }
    func validate(rootPath: String) async throws -> ProjectValidationReport { throw CancellationError() }
}
