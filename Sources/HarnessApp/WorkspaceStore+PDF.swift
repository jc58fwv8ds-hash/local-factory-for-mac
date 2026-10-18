import AppKit
import Foundation
import HarnessCore
import PDFKit

/// One PDF edit asked for in the chat (2026-10-11): the model lists operations, the app previews them in memory (pages,
/// what each step does, the first pages as pictures), and "適用する" writes 「〜_編集済み.pdf」 next to the first file.
@MainActor
@Observable
final class PDFChange: Identifiable {
    enum Status: Equatable { case running, ready, applied(URL), failed(String), discarded }
    let id: UUID
    let instruction: String
    let files: [URL]
    var status: Status = .running
    var operations: [PDFEditor.Operation] = []
    var steps: [String] = []
    var pageCount = 0
    var thumbnails: [NSImage] = []

    init(id: UUID, instruction: String, files: [URL]) {
        self.id = id
        self.instruction = instruction
        self.files = files
    }
}

enum PDFIntent {
    static func isEditRequest(_ text: String) -> Bool {
        ["結合", "まとめ", "つなげ", "分割", "抜き出", "取り出", "回転", "向き", "削除", "消して", "外して", "透かし", "スタンプ",
         "注釈", "メモを", "記入", "入力して", "並べ替え", "入れ替え", "順番"].contains { text.contains($0) }
    }

    static func prompt(instruction: String, files: [URL]) -> String {
        let described = files.enumerated().map { index, url -> String in
            let document = PDFDocument(url: url)
            let fields = (0..<(document?.pageCount ?? 0)).flatMap { document?.page(at: $0)?.annotations ?? [] }.compactMap(\.fieldName)
            let head = document?.page(at: 0)?.string?.prefix(200).replacingOccurrences(of: "\n", with: " ") ?? ""
            return "ファイル\(index + 1): \(url.lastPathComponent)(\(document?.pageCount ?? 0) ページ)"
                + (fields.isEmpty ? "" : " 記入欄: " + fields.joined(separator: "、")) + "\n  1ページ目の文字: \(head)"
        }.joined(separator: "\n")
        return """
        ユーザーは PDF をこう編集したい:
        \(instruction)

        添付された PDF:
        \(described)

        行う操作を順に JSON 一つで返してください。最初のファイルに対して順に行います。使える操作:
        {"op":"merge","files":[2,3]}  ほかのファイルを後ろにつなげる
        {"op":"extract","pages":"1-3,5"}  そのページだけ残す
        {"op":"remove","pages":"2"}  そのページを外す
        {"op":"reorder","pages":"3,1,2"}  ページの順を変える
        {"op":"rotate","pages":"all","degrees":90}  回転
        {"op":"watermark","text":"社外秘"}  全ページに透かし
        {"op":"note","page":1,"text":"確認してください"}  注釈のメモ
        {"op":"fill","fields":{"氏名":"山田太郎"}}  フォームの欄に記入
        形式: {"operations": [...]}。ページ番号は1から。JSON だけを返してください。
        """
    }

    static func operations(from response: String) -> [PDFEditor.Operation]? {
        struct Envelope: Decodable { let operations: [PDFEditor.Operation] }
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}") else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: Data(response[start...end].utf8)))?.operations
    }
}

extension WorkspaceStore {
    func submitPDFEdit(_ text: String) -> Bool {
        let files = documentAttachments.filter { $0.kind == "PDF" }.compactMap(\.sourcePath).map { URL(fileURLWithPath: $0) }
        guard !files.isEmpty, let model = project.selectedModel, PDFIntent.isEditRequest(text) else { return false }
        let message = ConversationMessage(role: .user, content: text + "\n(添付: " + files.map(\.lastPathComponent).joined(separator: "、") + ")",
                                          origin: .user)
        library.updateSelectedProject { $0.conversation.append(message) }
        persist()
        let change = PDFChange(id: message.id, instruction: text, files: files)
        pdfChanges[message.id] = change
        Task { await runPDFChange(change, model: model) }
        return true
    }

    func runPDFChange(_ change: PDFChange, model: ModelSelection) async {
        do {
            let request = InferenceRequest(runtime: model.runtime, modelIdentifier: model.identifier, messages: [
                InferenceMessage(role: .user, content: PDFIntent.prompt(instruction: change.instruction, files: change.files))],
                maximumOutputTokens: 800, temperature: 0)
            var response = ""
            for try await piece in await lightJobEvents(request) { response += piece }
            guard let operations = PDFIntent.operations(from: response), !operations.isEmpty else {
                change.status = .failed("PDF の操作を読み取れませんでした。ページや操作を具体的に書いて、もう一度頼んでください。"); return
            }
            let (document, steps) = try PDFEditor.apply(operations, files: change.files)
            change.operations = operations
            change.steps = steps
            change.pageCount = document.pageCount
            change.thumbnails = (0..<min(4, document.pageCount)).compactMap { document.page(at: $0)?.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox) }
            change.status = .ready
            appendAssistantNote("PDF の編集案ができました(\(steps.count) 手、\(document.pageCount) ページ)。確かめて「適用する」を押すと、新しいファイルに書き出します。")
        } catch {
            change.status = .failed(error.localizedDescription)
        }
    }

    func applyPDFChange(_ change: PDFChange) {
        guard change.status == .ready, let first = change.files.first else { return }
        do {
            let output = PDFEditor.outputURL(for: first)
            try FileOperationRunner.perform(.init(kind: .pdf, action: .write, instruction: change.instruction,
                                                  reads: change.files, writes: [output]), hooks: fileOperationHooks) {
                let (document, _) = try PDFEditor.apply(change.operations, files: change.files)
                guard document.write(to: output) else { throw PDFEditor.Failure.write }
            }
            change.status = .applied(output)
            appendAssistantNote("「\(output.lastPathComponent)」に書き出しました(元のファイルはそのままです)。")
        } catch {
            change.status = .failed(error.localizedDescription)
        }
    }

    func revertPDFChange(_ change: PDFChange) {
        guard case .applied(let output) = change.status else { return }
        do {
            try FileOperationRunner.perform(.init(kind: .pdf, action: .revert, instruction: change.instruction,
                                                  reads: change.files, writes: [output]), hooks: fileOperationHooks) {
                try FileManager.default.trashItem(at: output, resultingItemURL: nil)
            }
            change.status = .ready
            appendAssistantNote("書き出した「\(output.lastPathComponent)」をゴミ箱へ移しました。")
        } catch {
            presentNotice(error.localizedDescription, kind: .information)
        }
    }

    func discardPDFChange(_ change: PDFChange) {
        if change.status == .ready || change.status == .running { change.status = .discarded }
    }
}
