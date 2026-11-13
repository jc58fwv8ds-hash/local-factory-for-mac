import HarnessCore
import Testing
@testable import HarnessApp

struct SetAsideOldTestsTests {
    private func target(_ path: String, _ message: String) -> BuildRepairTarget {
        BuildRepairTarget(relativePath: path, diagnostics: [BuildFailureDiagnostic(validationKind: .xcodeTest, relativePath: path,
                                                                                   line: nil, column: nil, message: message)])
    }

    @Test func onlyFailingTestsCanBeSetAside() {
        let tests = BuildRepairPlan(targets: [target("App/JapaneseSpeaker.swift", "テスト convertsThreeBons が失敗(JapaneseSpeakerTests.swift): …")],
                                    unresolvedErrorCount: 0)
        #expect(FileChangeAutopilot.onlyTestsFail(tests))
    }

    @Test func codeThatDoesNotBuildIsNotSetAside() {
        let mixed = BuildRepairPlan(targets: [target("App/JapaneseSpeaker.swift", "テストが失敗しました(JapaneseSpeakerTests): x()"),
                                              target("App/SpeechListener.swift", "cannot find 'foo' in scope")],
                                    unresolvedErrorCount: 0)
        #expect(!FileChangeAutopilot.onlyTestsFail(mixed))
        #expect(!FileChangeAutopilot.onlyTestsFail(BuildRepairPlan(targets: [], unresolvedErrorCount: 0)))
    }
}
