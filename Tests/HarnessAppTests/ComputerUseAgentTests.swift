import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

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
        // 2026-10-18: typing replaced an open note's body. A field with text, or a document body, needs approval.
        let note = ComputerUseObservation(application: "メモ", window: "メモ", elements: [
            .init(id: 1, role: "AXTextArea", label: "", value: "前からある大事な文章"),
            .init(id: 2, role: "AXTextArea", label: "本文", value: ""),
            .init(id: 3, role: "AXTextField", label: "検索", value: "古い言葉")])
        if case .needsApproval = ComputerUseRisk.assess(.type(1, "買い物リスト"), in: note) {} else { Issue.record("filled body") }
        if case .needsApproval = ComputerUseRisk.assess(.type(2, "買い物リスト"), in: note) {} else { Issue.record("document body") }
        if case .needsApproval = ComputerUseRisk.assess(.type(3, "新しい言葉"), in: note) {} else { Issue.record("filled field") }
        let fresh = ComputerUseObservation(application: "テキストエディット", window: "名称未設定", elements: [
            .init(id: 1, role: "AXTextArea", label: "", value: ""), .init(id: 2, role: "AXTextArea", label: "", value: "書きかけ")])
        #expect(ComputerUseRisk.assess(.type(1, "テストです"), in: fresh) == .safe)
        if case .needsApproval = ComputerUseRisk.assess(.type(2, "テストです"), in: fresh) {} else { Issue.record("filled new doc") }
    }

    @Test func picturesArePointedAtSafely() {
        let picture = ComputerUseObservation(application: "ゲーム", window: "設定", elements: [], screenshot: Data([0]))
        #expect(ComputerUseAgentPrompt.parse(#"{"action":"click","x":0.5,"y":0.25,"target":"音量"}"#) == .click(0.5, 0.25, "音量"))
        #expect(ComputerUseRisk.assess(.click(0.5, 0.25, "音量"), in: picture) == .safe)
        if case .needsApproval = ComputerUseRisk.assess(.click(0.5, 0.9, "データを削除"), in: picture) {} else { Issue.record("delete") }
        if case .forbidden = ComputerUseRisk.assess(.click(1.4, 0.2, "外"), in: picture) {} else { Issue.record("outside") }
        if case .forbidden = ComputerUseRisk.assess(.click(0.5, 0.2, "x"), in: screen) {} else { Issue.record("no picture") }
        if case .needsApproval = ComputerUseRisk.assess(.write("こんにちは"), in: picture) {} else { Issue.record("write") }
        #expect(ComputerUseAgentPrompt.messages(goal: "g", observation: picture, history: [])[0].content.contains("\"click\""))
        #expect(!ComputerUseAgentPrompt.messages(goal: "g", observation: screen, history: [])[0].content.contains("\"click\""))
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
                                                 decide: { _, _ in await replies.next() }, approve: { _, _ in false })
        if case .stopped = outcome {} else { Issue.record("refused send stops the run: \(outcome)") }
        #expect(await fake.performed == [.type(1, "a@example.com")])
    }

    @Test func approvedStepsRunAndTheGoalFinishes() async {
        let fake = Fake(screen: screen)
        let replies = Replies([#"{"action":"press","id":3}"#, #"{"action":"done","summary":"送信しました"}"#])
        let outcome = await ComputerUseAgent.run(goal: "送って", controller: fake,
                                                 decide: { _, _ in await replies.next() }, approve: { _, _ in true })
        #expect(outcome == .done("送信しました"))
        #expect(await fake.performed == [.press(3)])
    }

    @Test func theSameActionIsNotRepeatedEndlessly() async {
        let fake = Fake(screen: screen)
        let replies = Replies(Array(repeating: #"{"action":"press","id":5}"#, count: 10))
        let outcome = await ComputerUseAgent.run(goal: "保存して", controller: fake,
                                                 decide: { _, _ in await replies.next() }, approve: { _, _ in true })
        if case .needsUser = outcome {} else { Issue.record("stops: \(outcome)") }
        #expect(await fake.performed.count == 2)
    }

    @Test func aPasswordIsLeftToTheUser() async {
        let fake = Fake(screen: screen)
        let replies = Replies([#"{"action":"type","id":4,"text":"hunter2"}"#])
        let outcome = await ComputerUseAgent.run(goal: "ログインして", controller: fake,
                                                 decide: { _, _ in await replies.next() }, approve: { _, _ in true })
        if case .needsUser = outcome {} else { Issue.record("password goes to the user: \(outcome)") }
        #expect(await fake.performed.isEmpty)
    }
}

/// Stage 2: every step, approval and outcome of a Computer Use run is written to the day's journal.
@MainActor
struct ComputerUseJournalTests {
    @Test func aRunIsJournaledStepByStep() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cu-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let screen = ComputerUseObservation(application: "テキストエディット", window: "名称未設定", elements: [
            .init(id: 1, role: "AXButton", label: "削除")])
        let session = ComputerUseSession(controller: ComputerUseAgentTests.Fake(screen: screen), journal: ComputerUseJournal(folder: folder))
        struct Model: ModelInferenceProvider {
            func events(for request: InferenceRequest) async -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.yield(#"{"action":"press","id":1}"#); $0.finish() }
            }
        }
        session.goal = "閉じて"
        session.start(model: ModelSelection(identifier: "m", displayName: "m", runtime: .ollama), provider: Model())
        for _ in 0..<200 where session.pendingApproval == nil { try await Task.sleep(for: .milliseconds(10)) }
        session.answer(false)
        for _ in 0..<200 where session.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        let file = try #require(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        #expect((lines.first?["approval"] as? [String: Any])?["allowed"] as? Bool == false)
        #expect(lines.contains { ($0["result"] as? String) == "ユーザーが止めた" })
        #expect(lines.last?["outcome"] != nil && lines.allSatisfy { $0["goal"] as? String == "閉じて" })
    }
}
