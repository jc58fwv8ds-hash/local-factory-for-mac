import Foundation
@testable import HarnessApp
import HarnessCore
import Testing

@MainActor
struct CodeChatFollowUpTests {
    // 2026-11-16: the chat of 14Translate.
    @Test func thatPlanCarriesTheRequestAndTheAnswer() throws {
        let conversation = [
            ConversationMessage(role: .user, content: "用語集を作り直して。最初の中身は No cap=マジで、güey=おまえ。PLaMo にない欄は作らないで。", origin: .user),
            ConversationMessage(role: .assistant, content: "用語集・言語切替・編集画面を作り直す案にするね。SlangGlossary.swift に 25 語を入れて…", origin: .localModel)
        ]
        let text = try #require(CodeChatFollowUp.request("その案で作って。", conversation: conversation))
        #expect(text.hasPrefix("その案で作って。"))
        #expect(text.contains("No cap=マジで、güey=おまえ"))
        #expect(text.contains("SlangGlossary.swift に 25 語"))
        let again = conversation + [ConversationMessage(role: .user, content: "その案で作って。", origin: .user),
                                    ConversationMessage(role: .assistant, content: "止めました。", origin: .localModel)]
        #expect(CodeChatFollowUp.request("その案で作って。", conversation: again)?.contains("No cap=マジで") == true)
        #expect(CodeChatFollowUp.request("用語集に bet=了解 を足して", conversation: conversation) == nil)
        #expect(CodeChatFollowUp.pointsBack("それでお願い"))
        #expect(CodeChatFollowUp.pointsBack("今の方向で進めて"))
    }

    @Test func aRuleAboutWhatToMakeIsStillWork() {
        #expect(CodeChatIntent.asksForWork("作り直して。PLaMo にない欄は作らないで。"))
        #expect(CodeChatIntent.asksForWork("状態を画面に出すように直して。通信の中身は変えないで。"))
        #expect(!CodeChatIntent.asksForWork("案を出して。まだファイルは変えないでね"))
        #expect(!CodeChatIntent.asksForWork("まだ何も作らないで"))
        #expect(!CodeChatIntent.asksForWork("コードは触らないで"))
        #expect(CodeChatIntent.asksForWork("翻訳の部分にある数字の読み方とそのテストは、読み上げの部分と同じことをしているので、翻訳の部分からは外して、読み上げの部分にまとめて。"))
        #expect(CodeChatIntent.asksForWork("ボタンを右に寄せてください"))
        #expect(!CodeChatIntent.asksForWork("この関数のしていることを教えて"))
        #expect(!CodeChatIntent.asksForWork("いくつか案を出して"))
        #expect(!CodeChatIntent.asksForWork("ちょっと待って"))
        #expect(!CodeChatIntent.asksForWork("続けて"))
        #expect(CodeChatIntent.asksForWork("演説って出るだけ"))
        #expect(CodeChatIntent.mentionsNotWorking("英語しか出ない"))
        #expect(!CodeChatIntent.asksForWork("進めて。"))
    }
}

struct AutopilotLeftoverTests {
    @Test func theErrorsLeftAreWrittenOutAndAContinueOnlyFixesThem() {
        let plan = BuildRepairPlan(targets: [BuildRepairTarget(relativePath: "App/TranslationScreen.swift", diagnostics: [
            BuildFailureDiagnostic(validationKind: .build, relativePath: "App/TranslationScreen.swift", line: 164, column: 13,
                                   message: "extra argument 'store' in call")
        ])], unresolvedErrorCount: 0)
        let text = FileChangeAutopilot.leftoverErrors(plan)
        #expect(text.contains("TranslationScreen.swift 164 行目: extra argument 'store' in call"))
        #expect(FileChangeAutopilot.leftoverErrors(nil).isEmpty)
        let root = "/tmp/leftover-test-\(UUID().uuidString)"
        FileChangeAutopilot.setPendingRepair(true, root: root)
        #expect(FileChangeAutopilot.hasPendingRepair(root: root))
        FileChangeAutopilot.setPendingRepair(false, root: root)
        #expect(!FileChangeAutopilot.hasPendingRepair(root: root))
    }
}
