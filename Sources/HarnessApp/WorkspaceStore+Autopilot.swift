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
        if continues {
            // After a restart the last request is the latest one in this project's chat that asked for work.
            let fromChat = record.project.conversation.last { $0.role == .user && CodeChatIntent.asksForWork($0.content) }?.content
            guard let last = AutopilotRequests.shared.lastText[record.id] ?? fromChat else { return false }
            text = last
        }
        guard !text.isEmpty, continues || !CodeChatIntent.isQuestion(text) else { return false }
        let typed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        library.updateSelectedProject { $0.conversation.append(ConversationMessage(role: .user, content: typed, origin: .user)) }
        appendAssistantNote("おまかせで進めます。必要なファイルを考えて、作って、ビルドとテストで確かめ、うまくいかなければ直します。"
            + "進み具合はここに書きます。止めたいときは開いた画面の「止める」を押してください。")
        AutopilotRequests.shared.request(text, projectID: record.id)
        instruction = ""
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

    static func asksForWork(_ text: String) -> Bool {
        let holds = ["変えないで", "作らないで", "触らないで", "まだ何も", "相談", "言い直", "説明して", "教えて", "どう思う"]
        if holds.contains(where: text.contains) { return false }
        let work = ["作って", "直して", "追加して", "足して", "変えて", "消して", "つないで", "組み込んで", "書いて", "実装して",
                    "修正して", "対応して", "入れて", "作成して", "動くようにして", "できるようにして", "直してくれ", "追加してくれ"]
        return work.contains(where: text.contains)
    }
}
