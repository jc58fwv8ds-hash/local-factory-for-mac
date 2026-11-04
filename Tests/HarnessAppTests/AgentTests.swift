import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

/// The agent screen (2026-11-02): Safari pages and web search on this Mac as actions, and a request after a question
/// continuing the earlier goal.
struct AgentTests {
    let empty = ComputerUseObservation(application: "(操作中のアプリなし)", window: "", elements: [])

    @Test func pagesAndSearchesAreParsedAndAssessed() {
        #expect(ComputerUseAgentPrompt.parse(#"{"action":"open_url","url":"https://www.apple.com/jp/"}"#) == .openURL("https://www.apple.com/jp/"))
        #expect(ComputerUseAgentPrompt.parse(#"{"action":"search","query":"東京 天気"}"#) == .search("東京 天気"))
        #expect(ComputerUseRisk.assess(.openURL("https://www.apple.com/jp/"), in: empty) == .safe)
        #expect(ComputerUseRisk.assess(.search("東京 天気"), in: empty) == .safe)
        for url in ["file:///etc/passwd", "javascript:alert(1)", "ftp://example.com", "https://", "なにか"] {
            if case .forbidden = ComputerUseRisk.assess(.openURL(url), in: empty) {} else { Issue.record("\(url) is not opened") }
        }
        let system = ComputerUseAgentPrompt.messages(goal: "g", observation: empty, history: [])[0].content
        #expect(system.contains("\"open_url\"") && system.contains("\"search\"") && system.contains("個人の情報を入れない") && system.contains("アドレス欄に打ち込まない"))
    }

    actor Fake: ComputerUseControlling {
        var performed: [ComputerUseAction] = []
        let screen: ComputerUseObservation
        init(screen: ComputerUseObservation) { self.screen = screen }
        func observe() async throws -> ComputerUseObservation { screen }
        func perform(_ action: ComputerUseAction, in observation: ComputerUseObservation) async throws -> String {
            performed.append(action); return "済み"
        }
    }

    actor Prompts {
        var replies = [#"{"action":"search","query":"Swift Observation"}"#, #"{"action":"done","summary":"まとめました"}"#]
        var seen: [String] = []
        func next(_ messages: [InferenceMessage]) -> String { seen.append(messages[1].content); return replies.removeFirst() }
    }

    @Test func searchResultsBecomeNotesWithoutTouchingTheScreen() async {
        let fake = Fake(screen: empty), prompts = Prompts()
        let outcome = await ComputerUseAgent.run(goal: "調べて", controller: fake,
                                                 decide: { messages, _ in await prompts.next(messages) }, approve: { _, _ in false },
                                                 search: { query in "1. 結果の題名\nhttps://example.com/\n\(query) の説明" })
        #expect(outcome == .done("まとめました"))
        #expect(await fake.performed.isEmpty)
        let second = await prompts.seen[1]
        #expect(second.contains("調べた内容:") && second.contains("https://example.com/"))
    }

    @Test func anAnswerContinuesTheGoalThatAskedForIt() {
        #expect(AgentGoal.compose(request: " 天気を調べて ", entries: []) == "天気を調べて")
        let asked: [AgentEntry] = [
            .init(kind: .request, text: "メールを書いて", detail: "メールを書いて"),
            .init(kind: .outcome, text: "あなたの判断が必要です: 宛先は誰ですか", detail: "宛先は誰ですか")]
        let goal = AgentGoal.compose(request: "田中さん", entries: asked)
        #expect(goal.hasPrefix("メールを書いて") && goal.contains("宛先は誰ですか") && goal.contains("ユーザーの答え: 田中さん"))
        let finished = asked + [.init(kind: .outcome, text: "完了しました: 下書きにしました")]
        let next = AgentGoal.compose(request: "次の依頼", entries: finished)
        #expect(next.hasPrefix("次の依頼") && next.contains("メールを書いて") && next.contains("下書きにしました"))
        #expect(!next.contains("ユーザーの答え"))
    }

    @Test func searchNotesKeepTheTopPagesShort() {
        let results: [[String: Any]] = (1...6).map { ["title": "題\($0)", "url": "https://e.com/\($0)", "content": "要約", "raw_content": String(repeating: "あ", count: 3000)] }
        let notes = LocalWebSearch.notes(results)
        #expect(notes.contains("4. 題4") && !notes.contains("題5"))
        #expect(notes.components(separatedBy: "本文: ").count == 2)   // the top page only
        #expect(notes.count < 1_500)
        #expect(LocalWebSearch.notes([]) == "(結果なし)")
    }
}

/// Pairing a device (2026-11-02, after Casement): both screens show the same 6 digits, someone in between cannot make them
/// match, and the device key never travels.
struct AgentPairingTests {
    @Test func bothSidesAgreeAndAManInTheMiddleShowsDifferentDigits() throws {
        let mac = AgentPairing(), device = AgentPairing()
        let onMac = try mac.complete(peerPublicKey: device.publicKey, macKey: mac.publicKey, deviceKey: device.publicKey)
        let onDevice = try device.complete(peerPublicKey: mac.publicKey, macKey: mac.publicKey, deviceKey: device.publicKey)
        #expect(onMac == onDevice)
        #expect(onMac.code.count == 6 && onMac.code.allSatisfy(\.isNumber) && onMac.deviceKey.count == 32)
        // Someone between swaps in their own key towards each side.
        let mallory = AgentPairing()
        let macSees = try mac.complete(peerPublicKey: mallory.publicKey, macKey: mac.publicKey, deviceKey: mallory.publicKey)
        let deviceSees = try device.complete(peerPublicKey: mallory.publicKey, macKey: mallory.publicKey, deviceKey: device.publicKey)
        #expect(macSees.code != deviceSees.code)
        #expect(macSees.deviceKey != onMac.deviceKey)
    }

    @Test func commandsBecomeOpsForTheSameCore() throws {
        let id = UUID()
        let line = try AgentWire.line(AgentWire.Command(kind: .approve, id: id, allowed: true))
        let back = try AgentWire.decode(AgentWire.Command.self, from: line.dropLast())
        #expect(back.op == .approve(id, true))
        #expect(AgentWire.Command(kind: .request, text: "天気を調べて").op == .request("天気を調べて", .remote))
        #expect(AgentWire.Command(kind: .pair, deviceName: "iPhone").op == nil)
        #expect((try? AgentWire.decode(AgentWire.Command.self, from: Data(count: AgentWire.maximumLine + 1))) == nil)
    }
}

/// What the user can change about the checks (2026-11-02): registered phrases stop counting, the two lines stay.
struct ContentGuardSettingsTests {
    @Test func registeredPhrasesStopAFalseDetectionButNotTheLines() {
        let text = "女子高生だった頃を思い出す30歳の女性の官能小説を書いて"
        if case .block = ContentGuard.check(text) {} else { Issue.record("the false detection this setting is for") }
        #expect(ContentGuard.check(text, exceptions: ["女子高生だった頃"]) == .allow)
        // A stated age under 18 still blocks, registered or not.
        if case .block = ContentGuard.check("16歳の、女子高生だった頃の官能小説", exceptions: ["女子高生だった頃", "16歳の、女子"]) {} else { Issue.record("age") }
        // A listed word alone (or nearly) cannot be registered; an everyday phrase can.
        #expect(ContentGuard.exceptionProblem("小学生") != nil)
        #expect(ContentGuard.exceptionProblem("ヌード絵") != nil)   // a core word with almost nothing around it
        #expect(ContentGuard.exceptionProblem("12歳の頃の話") != nil)
        #expect(ContentGuard.exceptionProblem("子どもの頃の写真") == nil)
        if case .block = ContentGuard.check("小学生が出てくるエロ漫画", exceptions: ["小学生"]) {} else { Issue.record("unregistrable phrase ignored") }
    }

    @Test func settingsKeepPhrasesAndChooseTheRefusalModel() {
        let defaults = UserDefaults(suiteName: "ContentGuardSettingsTests-\(UUID().uuidString)")!
        let settings = ContentGuardSettings(defaults: defaults)
        #expect(settings.add("小学生") != nil && settings.exceptions.isEmpty)
        #expect(settings.add("子どもの頃の写真") == nil && settings.exceptions == ["子どもの頃の写真"])
        let option = PurposeModelOption(id: "u", label: "U", runtime: .backburner, model: "gguf:/x.gguf")
        let catalog = PurposeModelCatalog(writing: [option], codeRefusalFallback: "u", conversation: [option])
        #expect(settings.refusalFallback(catalog: catalog)?.identifier == "gguf:/x.gguf")
        settings.retryRefusals = false
        #expect(settings.refusalFallback(catalog: catalog) == nil)
        #expect(catalog.options(for: .conversation) == [option])
        settings.remove("子どもの頃の写真")
        #expect(settings.exceptions.isEmpty)
    }
}

/// The screen as the model reads it (2026-11-04): short, with the numbers of the full list.
struct ComputerUseCompactScreenTests {
    @Test func unnamedButtonsAndLongListsAreLeftOutAndNumbersStay() {
        var elements = [ComputerUseElement(id: 1, role: "AXButton", label: "", value: "", enabled: true),
                        ComputerUseElement(id: 2, role: "AXTextField", label: "", value: "", enabled: true)]
        elements += (3...100).map { ComputerUseElement(id: $0, role: "AXButton", label: "押す\($0)", value: "", enabled: true) }
        elements += (101...200).map { ComputerUseElement(id: $0, role: "AXStaticText", label: String(repeating: "字", count: 100), value: "", enabled: true) }
        let text = ComputerUseObservation(application: "A", window: "W", elements: elements).text
        #expect(!text.contains("[1] ") && text.contains("[2] AXTextField") && text.contains("[3] AXButton 「押す3」"))
        #expect(text.contains("[61] AXButton") && !text.contains("[62] AXButton"))
        #expect(text.components(separatedBy: "AXStaticText").count == 31)
        #expect(text.contains("(ほか 110 件は省略)"))
    }
}

/// The word lists (2026-11-02, 2026-11-04): the user adds, removes and restores words; only the core words stay.
struct ContentGuardWordListTests {
    @Test func addedWordsCatchMoreAndCoreWordsStay() {
        let defaults = UserDefaults(suiteName: "ContentGuardWordListTests-\(UUID().uuidString)")!
        let settings = ContentGuardSettings(defaults: defaults)
        let text = "ランドセルの子が出てくるエロ漫画"
        #expect(settings.check(text, attachesPhoto: false) == .allow)
        settings.add("ランドセル", to: .minor)
        if case .block = settings.check(text, attachesPhoto: false) {} else { Issue.record("an added minor word catches") }
        settings.add("小学生", to: .minor)   // a core word: not added, and cannot be removed
        #expect(settings.added(.minor) == ["ランドセル"])
        settings.remove("小学生", from: .minor)
        if case .block = settings.check("小学生の性交を描いた漫画", attachesPhoto: false) {} else { Issue.record("core stays") }
        settings.remove("ランドセル", from: .minor)
        #expect(settings.check(text, attachesPhoto: false) == .allow)
    }

    @Test func defaultWordsAreTheUsersToRemoveAndRestore() {
        let defaults = UserDefaults(suiteName: "ContentGuardDefaults-\(UUID().uuidString)")!
        let settings = ContentGuardSettings(defaults: defaults)
        let text = "女子高生のエロ漫画"
        if case .block = settings.check(text, attachesPhoto: false) {} else { Issue.record("defaults count") }
        settings.remove("女子高生", from: .minor)
        #expect(settings.check(text, attachesPhoto: false) == .allow)
        #expect(settings.removedDefaults(.minor) == ["女子高生"])
        settings.add("女子高生", to: .minor)   // putting a default back
        if case .block = settings.check(text, attachesPhoto: false) {} else { Issue.record("restored by adding") }
        settings.remove("エロ", from: .sexual)
        settings.restoreDefaults(.sexual)
        #expect(settings.words(.sexual) == ContentGuard.defaultSexualWords)
        // A sexual word alone blocks nothing: adult research and life drawing pass.
        #expect(settings.check("成人の性交についての研究資料と、ヌードデッサンの参考画像", attachesPhoto: false) == .allow)
        // An age under 18 written out blocks whatever words are removed.
        for word in ContentGuard.defaultSexualWords { settings.remove(word, from: .sexual) }
        if case .block = settings.check("15歳のヌード", attachesPhoto: false) {} else { Issue.record("stated age stays") }
    }
}
