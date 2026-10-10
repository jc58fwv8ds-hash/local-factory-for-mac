import AppKit
import Foundation
import HarnessCore

/// One Word edit asked for in the chat (2026-10-11): the model quotes the exact text to change and gives the new text;
/// the app previews it on a scratch copy (before → after per paragraph) and "適用する" writes 「〜_編集済み.docx」.
@MainActor
@Observable
final class WordChange: Identifiable {
    enum Status: Equatable { case running, ready, applied(URL), failed(String), discarded }
    let id: UUID
    let instruction: String
    let source: URL
    var status: Status = .running
    var edits: [WordEditor.Edit] = []
    var changes: [WordEditor.Change] = []

    init(id: UUID, instruction: String, source: URL) {
        self.id = id
        self.instruction = instruction
        self.source = source
    }
}

enum WordIntent {
    static func prompt(instruction: String, name: String, paragraphs: [String]) -> String {
        """
        ユーザーは Word 文書「\(name)」をこう直したい:
        \(instruction)

        文書の段落:
        \(paragraphs.prefix(300).enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n"))

        変える部分を JSON 一つで返してください。find には段落の中の文字を一字一句そのまま(番号は含めない)、replace には新しい文字:
        {"edits": [{"find": "日時は10月20日です。", "replace": "日時は10月27日です。"}]}
        消す場合は replace を空にする。依頼にない部分は変えない。JSON だけを返してください。
        """
    }

    static func edits(from response: String) -> [WordEditor.Edit]? {
        struct Envelope: Decodable { let edits: [WordEditor.Edit] }
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}") else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: Data(response[start...end].utf8)))?.edits
    }
}

extension WorkspaceStore {
    func submitWordEdit(_ text: String) -> Bool {
        guard let document = documentAttachments.first(where: { $0.kind == "Word" && $0.sourcePath?.lowercased().hasSuffix(".docx") == true }),
              let path = document.sourcePath, let model = project.selectedModel, SpreadsheetIntent.isEditRequest(text) else { return false }
        let message = ConversationMessage(role: .user, content: text + "\n(添付: \(document.displayName))", origin: .user)
        library.updateSelectedProject { $0.conversation.append(message) }
        persist()
        let change = WordChange(id: message.id, instruction: text, source: URL(fileURLWithPath: path))
        wordChanges[message.id] = change
        Task { await runWordChange(change, model: model) }
        return true
    }

    func runWordChange(_ change: WordChange, model: ModelSelection) async {
        do {
            let paragraphs = try WordEditor.paragraphs(of: change.source)
            let request = InferenceRequest(runtime: model.runtime, modelIdentifier: model.identifier, messages: [
                InferenceMessage(role: .user, content: WordIntent.prompt(instruction: change.instruction,
                    name: change.source.lastPathComponent, paragraphs: paragraphs))], maximumOutputTokens: 1500, temperature: 0)
            var response = ""
            for try await piece in await inferenceProvider.events(for: request) { response += piece }
            guard let edits = WordIntent.edits(from: response), !edits.isEmpty else {
                change.status = .failed("直す部分を読み取れませんでした。どの文をどう直すか具体的に書いて、もう一度頼んでください。"); return
            }
            let preview = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).docx")
            defer { try? FileManager.default.removeItem(at: preview) }
            change.changes = try WordEditor.apply(edits, to: change.source, output: preview)
            change.edits = edits
            change.status = .ready
            appendAssistantNote("文書の直し案ができました(\(edits.count) か所)。確かめて「適用する」を押すと、元のファイルはそのままで、新しいファイルに書き出します。")
        } catch {
            change.status = .failed(error.localizedDescription)
        }
    }

    func applyWordChange(_ change: WordChange) {
        guard change.status == .ready else { return }
        let output = WordEditor.outputURL(for: change.source)
        do {
            _ = try WordEditor.apply(change.edits, to: change.source, output: output)
            change.status = .applied(output)
            appendAssistantNote("「\(output.lastPathComponent)」に書き出しました(元のファイルはそのままです)。")
        } catch {
            change.status = .failed(error.localizedDescription)
        }
    }

    func revertWordChange(_ change: WordChange) {
        guard case .applied(let output) = change.status else { return }
        do {
            try FileManager.default.trashItem(at: output, resultingItemURL: nil)
            change.status = .ready
            appendAssistantNote("書き出した「\(output.lastPathComponent)」をゴミ箱へ移しました。")
        } catch {
            presentNotice(error.localizedDescription, kind: .information)
        }
    }

    func discardWordChange(_ change: WordChange) {
        if change.status == .ready || change.status == .running { change.status = .discarded }
    }
}
