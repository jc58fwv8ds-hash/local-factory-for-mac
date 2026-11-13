import Foundation
import HarnessCore

/// The code chat as the way in (2026-11-10, the user: 「このチャット欄での僕の操作程度でファクトリーの操作も済む様になる
/// ことを実現してね」): a request sent in the code chat of a project with a source is built 「おまかせ」 — files planned,
/// written, built, tested and fixed — and how it goes is written back into the chat. A question is answered as before.
extension WorkspaceStore {
    func submitCodeAutopilot() -> Bool {
        // A Swift package keeps its own chat change (ChatChange); 「おまかせ」 is for the projects it does not take, such as
        // an iPhone app, whose code-chat requests used to end as text.
        guard workspaceMode == .code, chatCodeChangeContext == nil, documentAttachments.isEmpty, attachedFolder == nil,
              let record = library.selectedRecord, record.sourceLocation != nil else { return false }
        var text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        // 「続けて」: the last request again, from where the project now is (2026-11-10).
        let continues = CodeChatIntent.isContinue(text)
        // 「続けて」 after a split message: the requests of it not yet done well, one after another (2026-11-12).
        if continues, case let left = AutopilotRequests.shared.unfinished(projectID: record.id), !left.isEmpty {
            library.updateSelectedProject { $0.conversation.append(ConversationMessage(role: .user, content: text, origin: .user)) }
            appendAssistantNote("分けた依頼のうち、まだできていない \(left.count) 件を順に進めます。")
            instruction = ""
            AutopilotRequests.shared.request(all: left, projectID: record.id)
            return true
        }
        if continues {
            // After a restart the last request is the latest one in this project's chat that asked for work.
            let fromChat = record.project.conversation.last { $0.role == .user && CodeChatIntent.asksForWork($0.content) }?.content
            guard let last = AutopilotRequests.shared.lastText[record.id] ?? fromChat else { return false }
            text = last
        }
        guard !text.isEmpty, continues || !CodeChatIntent.isQuestion(text) else { return false }
        // An attached screenshot goes with the request as its text, where it is on the screen, and what a model that sees
        // pictures makes of it and of any markup drawn on it (2026-11-11).
        let pictures = visualAttachments.items.compactMap { item in
            item.textInspection.transcript.flatMap { ScreenshotDescription.describe(name: item.descriptor.displayName, lines: $0.lines) }
        }
        let images = visualAttachments.inferenceImages
        visualAttachments.clear()
        let typed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        library.updateSelectedProject { $0.conversation.append(ConversationMessage(role: .user, content: typed, origin: .user)) }
        appendAssistantNote("おまかせで進めます。必要なファイルを考えて、作って、ビルドとテストで確かめ、うまくいかなければ直します。"
            + "進み具合はここに書きます。止めたいときは開いた画面の「止める」を押してください。")
        instruction = ""
        // 「落ちる」: the iPhone's crash reports go with the request; 「動かない」: what in the code would keep it from working.
        let crash = CodeChatIntent.mentionsCrash(text), trouble = crash || CodeChatIntent.mentionsNotWorking(text)
        let several = RequestSplitting.mayHoldSeveral(text) && !continues
        guard trouble || !images.isEmpty || several, let root = record.sourceLocation else {
            AutopilotRequests.shared.request(text, projectID: record.id)
            return true
        }
        if !images.isEmpty { appendAssistantNote("付けてもらった画面写真を\(images.count > 1 ? " \(images.count) 枚とも" : "")見ています。書き込みがあれば、それも読みます。") }
        if trouble { appendAssistantNote(crash ? "アプリが止まった原因を、iPhone から調べています。" : "うまく動かない原因を調べています。") }
        let id = record.id
        Task { [weak self] in
            let seen = images.isEmpty ? nil : await self?.describeScreenshots(images, request: text)
            let picturesText = ([seen.map { "画面写真から読み取ったこと:\n" + $0 }].compactMap { $0 } + pictures).joined(separator: "\n\n")
            let context = crash ? await self?.crashContext(root: root) ?? nil : nil
            // What the app wrote while it ran on the iPhone (2026-11-13), and what it shows.
            let console = trouble ? DeviceConsoleLog.tail(projectRoot: root) : []
            let hints = trouble ? NotWorkingHints.hints(rootURL: URL(fileURLWithPath: root), request: text) + NotWorkingHints.fromConsole(console) : []
            if let self, trouble { self.noteTrouble(crash: crash, summary: context?.summary, hints: hints, projectID: id) }
            if let self, console.count > 1 { self.note("iPhone で動いていたときの記録も読みました(最後の \(console.count) 行)。", to: id) }
            // The app was opened again by hand, so the record stops before what the person saw (2026-11-13).
            if let self, console.last == DeviceConsoleLog.closedNote {
                self.note("ただ、iPhone の記録はアプリを一度閉じた所で終わっていて、そのあと開き直してからの様子は残っていません。"
                    + "次に試すときは、Factory が開いたアプリを閉じずにそのまま使ってください。", to: id)
            }
            let found = ([context?.detail].compactMap { $0 } + hints
                + (console.count > 1 ? ["iPhone で動いていたときのアプリの出力(最後の部分。止まった直前に何が起きたかの手がかり):\n" + console.joined(separator: "\n")] : []))
                .joined(separator: "\n")
            let items = several ? await self?.splitRequests(text, pictures: seen) ?? [text] : [text]
            if items.count > 1, let self {
                self.note("依頼を \(items.count) 件に分けました。順に進めます。\n" + items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"), to: id)
            }
            let requests = items.map { item -> String in
                let troubled = CodeChatIntent.mentionsCrash(item) || CodeChatIntent.mentionsNotWorking(item) || items.count == 1
                return ([item, items.count > 1 ? "(利用者のメッセージ全体: \(text))" : nil, picturesText.isEmpty ? nil : picturesText,
                         found.isEmpty || !troubled ? nil : (items.count > 1 ? CodeChatIntent.sharedFindingsHeading : "調べてわかったこと:\n") + found].compactMap { $0 }).joined(separator: "\n\n")
            }
            AutopilotRequests.shared.request(all: requests, projectID: id)
        }
        return true
    }
}

/// Whether a code-chat message asks for something to be made or changed; anything else stays a conversation
/// (「今の返答を言い直して。まだファイルは変えないでね」 is talk, not work).
enum CodeChatIntent {
    static func isQuestion(_ text: String) -> Bool { !asksForWork(text) }

    /// 「続けて」「進めて」 alone: carry on with the last request.
    static func isContinue(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "。.!！ 　"))
        return ["続けて", "進めて", "続けよう", "進めよう", "続きを", "続行", "やって", "お願い"].contains(cleaned)
    }

    /// 「iPhone に入れて」「実機で動かして」: the app onto the connected iPhone, not a change to the code.
    static func asksForDevice(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard ["iphone", "実機", "アイフォン", "スマホ"].contains(where: lowered.contains) else { return false }
        let fix = ["直して", "修正", "対応して", "作って", "追加", "足して"]
        return !fix.contains(where: text.contains)
            && ["入れて", "インストール", "動かして", "試して", "試したい", "起動して", "開いて", "転送"].contains(where: text.contains)
    }

    static func mentionsCrash(_ text: String) -> Bool {
        ["落ちる", "落ちた", "落ちて", "クラッシュ", "強制終了", "勝手に閉じ", "すぐ閉じ", "固まる", "フリーズ"].contains(where: text.contains)
    }

    static func mentionsNotWorking(_ text: String) -> Bool {
        ["動かない", "動かなかった", "機能していない", "機能しない", "反応しない", "何も起きない", "出ない", "鳴らない", "聞こえない",
         "読み上げない", "表示されない", "効かない", "止まる", "止まって", "おかしい", "変な読み", "読み間違", "ミス", "エラー",
         "効果なし", "効果がない", "皆無", "変わらず", "何も出ない", "無反応", "起こらない", "起きない", "反応がない",
         "遅れて", "数十秒", "始まらない", "リアルタイム", "待たされ", "間に合わない",
         "ダメ", "だめ", "駄目", "使えない", "意味がない", "使い物にならない",
         "抜けが", "抜けも", "抜けて", "抜ける", "欠けて", "飛ばされ", "途切れ",
         "諦め", "破綻", "疑わしい", "不自然", "精度が"].contains(where: text.contains)
            || failedAction(text) || slowReport(text)
    }

    /// 「…が遅く」「遅すぎる」 said as a report, not asked (2026-11-13: 「開始の速度が遅く結果分の抜けもある」 must be work; 「なぜ遅いの？」
    /// stays a question).
    static func slowReport(_ text: String) -> Bool {
        let asked = text.contains("?") || text.contains("？") || ["なぜ", "どうして", "何で", "なんで"].contains(where: text.contains)
        return !asked && ["遅く", "遅すぎ", "遅い。", "遅いね", "遅いよ", "遅れる"].contains(where: text.contains)
    }

    /// 「(何かを)しない」 said of what the app should do (2026-11-13: 「全く読み上げも翻訳も開始しない。繋いでないのと一緒」 went to
    /// the chat as a question): an action word followed by a negative, not a word list of every verb.
    /// Findings about the whole message, sent with each of its requests (2026-11-13: four requests — slowness, wording,
    /// AirPods, subtitles — each became the same fix of the same two findings, and none did what it asked).
    static let sharedFindingsHeading = "調べてわかったこと(メッセージ全体について調べたもの。この依頼に関係するものだけを使い、関係しないものは直さず、この依頼で頼まれたことを直すこと):\n"

    static func failedAction(_ text: String) -> Bool {
        text.range(of: #"(開始|起動|再生|翻訳|保存|送信|接続|読み込|表示|反映|録音|認識|聞き取|読み上げ|切り替|動作|更新|同期|通知|ログイン)"#
            + #"(が|も|は)?(し|され|でき|出来|さ)?(ない|ません|てない|ていない|なかった)"#, options: .regularExpression) != nil
            || text.range(of: #"(繋|つな|接続し)(いで|が)?(ない|ってない|っていない)の?と(一緒|同じ)"#, options: .regularExpression) != nil
    }

    static func asksForWork(_ text: String) -> Bool {
        let holds = ["変えないで", "作らないで", "触らないで", "まだ何も", "相談", "言い直", "説明して", "教えて", "どう思う"]
        if holds.contains(where: text.contains) { return false }
        if mentionsCrash(text) || mentionsNotWorking(text) { return true }
        // Feedback after trying the app is work too (2026-11-12: 「…が問題」「日本語だけで良いのでは？」「…できたら良いだけ
        // だよね」 went to the chat as a question, and its pictures were refused there).
        let wishes = ["問題", "良いのでは", "いいのでは", "できたら良い", "できたらいい", "すべき", "して欲しい", "してほしい",
                      "が欲しい", "がほしい", "にして", "ミス", "止まった", "おかしい"]
        if wishes.contains(where: text.contains) { return true }
        let work = ["作って", "直して", "追加して", "足して", "変えて", "消して", "つないで", "組み込んで", "書いて", "実装して",
                    "修正して", "対応して", "入れて", "作成して", "動くようにして", "できるようにして", "直してくれ", "追加してくれ"]
        return work.contains(where: text.contains)
    }
}
