import Foundation
import HarnessCore
import HarnessExecution
import Testing
@testable import HarnessApp

@MainActor
struct ValidationFailureNoticeTests {
    @Test func aCheckThatStopsOnAnErrorIsToldAndCanBeRetried() async throws {
        let provider = FailingOnceProvider()
        let session = ProjectValidationSession(rootPath: "/unused", provider: provider)
        var reasons: [String] = []
        var completed = 0
        session.onFailure = { reasons.append($0) }
        session.start(onComplete: { _ in completed += 1 })
        for _ in 0..<200 where reasons.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reasons.count == 1)
        #expect(!session.isRunning)
        session.retry()
        for _ in 0..<200 where completed == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(completed == 1)
        #expect(reasons.count == 1)
    }
}

private struct BrokenCheck: LocalizedError { var errorDescription: String? { "検証中にファイルが変わりました" } }

private actor FailingOnceProvider: ProjectValidating {
    var calls = 0
    func support(rootPath: String) async -> ProjectValidationSupport? { .init(system: .swiftPackage) }
    func validate(rootPath: String) async throws -> ProjectValidationReport {
        calls += 1
        if calls == 1 { throw BrokenCheck() }
        return .init(startedAt: .now, finishedAt: .now, checks: [])
    }
}
