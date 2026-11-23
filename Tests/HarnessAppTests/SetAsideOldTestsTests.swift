import Foundation
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

    @Test func aRequestAboutTheTestsBringsTheSetAsideOnesBack() {
        #expect(FileChangeAutopilot.asksAboutTests("日本語の読み上げのテストが前から通らないままになっている。直して"))
        #expect(FileChangeAutopilot.asksAboutTests("make the failing tests pass"))
        #expect(!FileChangeAutopilot.asksAboutTests("翻訳の訳を丁寧語にして"))
    }

    @Test func aTestsRequestIsRememberedForTheProject() {
        let root = "/tmp/tests-requested-\(UUID().uuidString)"
        FileChangeAutopilot.setTestsRequested(true, root: root)
        #expect(FileChangeAutopilot.testsRequested(root: root))
        FileChangeAutopilot.keepTestsRequested("続けて", root: root)
        #expect(FileChangeAutopilot.testsRequested(root: root))
        FileChangeAutopilot.keepTestsRequested("翻訳の訳を丁寧語にして、読み上げも少しゆっくりにして", root: root)
        #expect(!FileChangeAutopilot.testsRequested(root: root))
    }

    @Test func failingTestsAreCountedByName() {
        func diagnostic(_ message: String) -> BuildFailureDiagnostic {
            BuildFailureDiagnostic(validationKind: .xcodeTest, relativePath: "A.swift", line: nil, column: nil, message: message)
        }
        let plan = BuildRepairPlan(targets: [BuildRepairTarget(relativePath: "A.swift", diagnostics: [
            diagnostic("テスト yen が失敗(ATests.swift): x"), diagnostic("テスト yen が失敗(ATests.swift): y"),
            diagnostic("テスト pieces が失敗(ATests.swift): z"), diagnostic("行3: cannot find 'x'")
        ])], unresolvedErrorCount: 0)
        #expect(FileChangeAutopilot.failingTests(plan) == ["テスト yen", "テスト pieces"])
    }

    @Test func theRunningRequestIsKeptForTheRepairs() {
        let root = "/tmp/request-\(UUID().uuidString)"
        FileChangeAutopilot.keepTestsRequested("千の前が3のときだけ「ぜん」と濁る。テストが全部通るようにして", root: root)
        FileChangeAutopilot.keepTestsRequested("続けて", root: root)
        #expect(FileChangeAutopilot.currentRequest(root: root)?.contains("千の前が3のときだけ") == true)
    }
}
