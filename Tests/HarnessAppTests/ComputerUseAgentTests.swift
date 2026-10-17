import Foundation
import HarnessCore
import Testing

/// Computer Use stage 1 (2026-10-18): one action at a time on the accessibility elements, an approval before anything
/// that cannot be undone, and no typing into password fields.
struct ComputerUseAgentTests {
    let screen = ComputerUseObservation(application: "メール", window: "新規メッセージ", elements: [
        .init(id: 1, role: "AXTextField", label: "宛先"),
        .init(id: 2, role: "AXTextArea", label: "本文"),
        .init(id: 3, role: "AXButton", label: "送信"),
        .init(id: 4, role: "AXSecureTextField", label: "パスワード", value: "secret"),
        .init(id: 5, role: "AXButton", label: "下書きを保存"),
    ])

    @Test func risksAreAssessedBeforeActing() {
        #expect(ComputerUseRisk.assess(.type(1, "a@example.com"), in: screen) == .safe)
        #expect(ComputerUseRisk.assess(.press(5), in: screen) == .safe)
        if case .needsApproval = ComputerUseRisk.assess(.press(3), in: screen) {} else { Issue.record("送信 needs approval") }
        if case .forbidden = ComputerUseRisk.assess(.type(4, "x"), in: screen) {} else { Issue.record("password field is forbidden") }
        if case .forbidden = ComputerUseRisk.assess(.press(99), in: screen) {} else { Issue.record("unknown element") }
        if case .needsApproval = ComputerUseRisk.assess(.menu(["ファイル", "ゴミ箱に入れる"]), in: screen) {} else { Issue.record("menu delete") }
        if case .forbidden = ComputerUseRisk.assess(.key("cmd+option+escape"), in: screen) {} else { Issue.record("unknown key") }
        #expect(ComputerUseRisk.assess(.key("tab"), in: screen) == .safe)
        #expect(!screen.text.contains("secret"))   // the model never sees a secure field's value
    }

    @Test func repliesAreParsed() {
        #expect(ComputerUseAgentPrompt.parse(#"理由: 宛先から {"action": "type", "id": 1, "text": "a@example.com"}"#) == .type(1, "a@example.com"))
        #expect(ComputerUseAgentPrompt.parse(#"{"action":"press","id":"3"}"#) == .press(3))
        #expect(ComputerUseAgentPrompt.parse(#"{"action":"menu","path":["ファイル","新規"]}"#) == .menu(["ファイル", "新規"]))
        #expect(ComputerUseAgentPrompt.parse(#"{"action":"done","summary":"下書きにしました"}"#) == .done("下書きにしました"))
        #expect(ComputerUseAgentPrompt.parse(#"{"action":"rm -rf"}"#) == nil)
    }

    actor Fake: ComputerUseControlling {
        let screen: ComputerUseObservation
        var performed: [ComputerUseAction] = []
        init(screen: ComputerUseObservation) { self.screen = screen }
        func observe() async throws -> ComputerUseObservation { screen }
        func perform(_ action: ComputerUseAction, in observation: ComputerUseObservation) async throws -> String {
            performed.append(action); return "済み"
        }
    }

    actor Replies {
        var list: [String]
        init(_ list: [String]) { self.list = list }
        func next() -> String { list.isEmpty ? #"{"action":"done","summary":"終わり"}"# : list.removeFirst() }
    }

    @Test func theLoopStopsForApprovalAndNeverActsWhenRefused() async {
        let fake = Fake(screen: screen)
        let replies = Replies([#"{"action":"type","id":1,"text":"a@example.com"}"#, #"{"action":"press","id":3}"#])
        let outcome = await ComputerUseAgent.run(goal: "メールを送って", controller: fake,
                                                 decide: { _ in await replies.next() }, approve: { _, _ in false })
        if case .stopped = outcome {} else { Issue.record("refused send stops the run: \(outcome)") }
        #expect(await fake.performed == [.type(1, "a@example.com")])
    }

    @Test func approvedStepsRunAndTheGoalFinishes() async {
        let fake = Fake(screen: screen)
        let replies = Replies([#"{"action":"press","id":3}"#, #"{"action":"done","summary":"送信しました"}"#])
        let outcome = await ComputerUseAgent.run(goal: "送って", controller: fake,
                                                 decide: { _ in await replies.next() }, approve: { _, _ in true })
        #expect(outcome == .done("送信しました"))
        #expect(await fake.performed == [.press(3)])
    }

    @Test func aPasswordIsLeftToTheUser() async {
        let fake = Fake(screen: screen)
        let replies = Replies([#"{"action":"type","id":4,"text":"hunter2"}"#])
        let outcome = await ComputerUseAgent.run(goal: "ログインして", controller: fake,
                                                 decide: { _ in await replies.next() }, approve: { _, _ in true })
        if case .needsUser = outcome {} else { Issue.record("password goes to the user: \(outcome)") }
        #expect(await fake.performed.isEmpty)
    }
}
