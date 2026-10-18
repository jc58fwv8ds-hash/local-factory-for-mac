import Foundation
import HarnessCore

/// One spreadsheet edit asked for in the chat (2026-10-11): the model lists cell edits; the app previews them on a scratch
/// copy, shows before → after, and "適用する" writes a NEW file next to the original (「〜_編集済み.xlsx」).
/// "取り消す" moves that new file to the Trash. The original file is never written.
@MainActor
@Observable
final class SpreadsheetChange: Identifiable {
    enum Status: Equatable { case running, ready, applied(URL), failed(String), discarded }
    let id: UUID
    let instruction: String
    let source: URL
    var status: Status = .running
    var edits: [XLSXEditor.CellEdit] = []
    var changes: [XLSXEditor.CellChange] = []

    init(id: UUID, instruction: String, source: URL) {
        self.id = id
        self.instruction = instruction
        self.source = source
    }
}

enum SpreadsheetIntent {
    /// An instruction that asks to change the attached workbook (not only to read or explain it).
    static func isEditRequest(_ text: String) -> Bool {
        ["変えて", "変更して", "書き換え", "直して", "入れて", "入力して", "追加して", "足して", "増やして", "減らして", "にして",
         "埋めて", "記入して", "更新して", "置き換え"].contains { text.contains($0) }
    }

    static func prompt(instruction: String, name: String, cells: String) -> String {
        """
        ユーザーは Excel ファイル「\(name)」のセルを書き換えたい。依頼:
        \(instruction)

        今のセルの値(行番号: 列=値):
        \(cells)

        書き換えるセルを JSON 一つで返してください:
        {"edits": [{"sheet": "シート名", "cell": "B5", "value": "1200"}, {"sheet": "シート名", "cell": "B10", "formula": "=SUM(B2:B9)"}]}
        数値は数字だけ、文字はそのまま、計算は formula に Excel の数式で書く。依頼にないセルは書かない。JSON だけを返してください。
        """
    }

    static func edits(from response: String) -> [XLSXEditor.CellEdit]? {
        struct Envelope: Decodable { let edits: [XLSXEditor.CellEdit] }
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}") else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: Data(response[start...end].utf8)))?.edits
    }

    /// 「売上.xlsx」→「売上_編集済み.xlsx」(「売上_編集済み 2.xlsx」… when it exists).
    static func outputURL(for source: URL) -> URL {
        let folder = source.deletingLastPathComponent(), base = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent("\(base)_編集済み.xlsx"), n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)_編集済み \(n).xlsx"); n += 1
        }
        return candidate
    }
}

extension WorkspaceStore {
    /// A change request with an .xlsx attached becomes a spreadsheet card.
    func submitSpreadsheetEdit(_ text: String) -> Bool {
        guard let document = documentAttachments.first(where: { $0.kind == "Excel" && $0.sourcePath != nil }),
              let path = document.sourcePath, let model = project.selectedModel,
              SpreadsheetIntent.isEditRequest(text) else { return false }
        let message = ConversationMessage(role: .user, content: text + "\n(添付: \(document.displayName))", origin: .user)
        library.updateSelectedProject { $0.conversation.append(message) }
        persist()
        let change = SpreadsheetChange(id: message.id, instruction: text, source: URL(fileURLWithPath: path))
        spreadsheetChanges[message.id] = change
        Task { await runSpreadsheetChange(change, model: model) }
        return true
    }

    func runSpreadsheetChange(_ change: SpreadsheetChange, model: ModelSelection) async {
        do {
            let cells = try XLSXEditor.addressedText(change.source)
            let request = InferenceRequest(runtime: model.runtime, modelIdentifier: model.identifier, messages: [
                InferenceMessage(role: .user, content: SpreadsheetIntent.prompt(instruction: change.instruction,
                    name: change.source.lastPathComponent, cells: cells))], maximumOutputTokens: 1500, temperature: 0)
            var response = ""
            for try await piece in await lightJobEvents(request) { response += piece }
            guard let edits = SpreadsheetIntent.edits(from: response), !edits.isEmpty else {
                change.status = .failed("書き換えるセルを読み取れませんでした。セルや列を具体的に書いて、もう一度頼んでください。"); return
            }
            // Preview on a scratch copy: the before → after table comes from the real file, not from the model.
            let preview = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).xlsx")
            defer { try? FileManager.default.removeItem(at: preview) }
            change.changes = try XLSXEditor.apply(edits, to: change.source, output: preview)
            change.edits = edits
            change.status = .ready
            appendAssistantNote("セルの書き換え案ができました(\(edits.count) か所)。表を確かめて「適用する」を押すと、元のファイルはそのままで、新しいファイルに書き出します。")
        } catch {
            change.status = .failed(error.localizedDescription)
        }
    }

    func applySpreadsheetChange(_ change: SpreadsheetChange) {
        guard change.status == .ready else { return }
        let output = SpreadsheetIntent.outputURL(for: change.source)
        do {
            _ = try FileOperationRunner.perform(.init(kind: .excel, action: .write, instruction: change.instruction,
                                                      reads: [change.source], writes: [output]), hooks: fileOperationHooks) {
                try XLSXEditor.apply(change.edits, to: change.source, output: output)
            }
            change.status = .applied(output)
            appendAssistantNote("「\(output.lastPathComponent)」に書き出しました(元のファイルはそのままです)。")
        } catch {
            change.status = .failed(error.localizedDescription)
        }
    }

    /// Moves the written file to the Trash (recoverable there); the original was never changed.
    func revertSpreadsheetChange(_ change: SpreadsheetChange) {
        guard case .applied(let output) = change.status else { return }
        do {
            try FileOperationRunner.perform(.init(kind: .excel, action: .revert, instruction: change.instruction,
                                                  reads: [change.source], writes: [output]), hooks: fileOperationHooks) {
                try FileManager.default.trashItem(at: output, resultingItemURL: nil)
            }
            change.status = .ready
            appendAssistantNote("書き出した「\(output.lastPathComponent)」をゴミ箱へ移しました。")
        } catch {
            presentNotice(error.localizedDescription, kind: .information)
        }
    }

    func discardSpreadsheetChange(_ change: SpreadsheetChange) {
        if change.status == .ready || change.status == .running { change.status = .discarded }
    }
}

/// One analysis of attached tables (2026-10-11): the model writes SQL, DuckDB computes, the card shows the result table
/// and the SQL. One retry with the error when the SQL fails.
@MainActor
@Observable
final class AnalysisChange: Identifiable {
    enum Status: Equatable { case running, ready, failed(String) }
    let id: UUID
    let instruction: String
    var status: Status = .running
    var query = ""
    var result: SpreadsheetAnalysis.Result?

    init(id: UUID, instruction: String) {
        self.id = id
        self.instruction = instruction
    }
}

enum AnalysisIntent {
    static func isAnalysisRequest(_ text: String) -> Bool {
        ["集計", "合計", "平均", "件数", "何件", "いくつ", "分析", "上位", "下位", "ランキング", "比較", "推移", "傾向", "ごと",
         "最大", "最小", "割合", "中央値", "一番", "多い順", "少ない順"].contains { text.contains($0) }
    }
}

extension WorkspaceStore {
    func submitAnalysis(_ text: String) -> Bool {
        let sources = documentAttachments.filter { ["Excel", "表(CSV)"].contains($0.kind) }.compactMap(\.sourcePath)
        guard !sources.isEmpty, let model = project.selectedModel, AnalysisIntent.isAnalysisRequest(text) else { return false }
        let names = documentAttachments.filter { $0.sourcePath != nil }.map(\.displayName).joined(separator: "、")
        let message = ConversationMessage(role: .user, content: text + "\n(添付: \(names))", origin: .user)
        library.updateSelectedProject { $0.conversation.append(message) }
        persist()
        let change = AnalysisChange(id: message.id, instruction: text)
        analysisChanges[message.id] = change
        Task { await runAnalysis(change, sources: sources.map { URL(fileURLWithPath: $0) }, model: model) }
        return true
    }

    func runAnalysis(_ change: AnalysisChange, sources: [URL], model: ModelSelection) async {
        do {
            let tables = try SpreadsheetAnalysis.tables(from: sources)
            var previousError: String?
            for attempt in 1...2 {
                let request = InferenceRequest(runtime: model.runtime, modelIdentifier: model.identifier, messages: [
                    InferenceMessage(role: .user, content: SpreadsheetAnalysis.prompt(instruction: change.instruction, tables: tables,
                                                                                     previousError: previousError))],
                    maximumOutputTokens: 800, temperature: 0)
                var response = ""
                for try await piece in await lightJobEvents(request) { response += piece }
                guard let query = SpreadsheetAnalysis.sql(from: response) else {
                    previousError = "SELECT 文が見つかりません"; continue
                }
                change.query = query
                do {
                    change.result = try SpreadsheetAnalysis.run(query, tables: tables)
                    change.status = .ready
                    appendAssistantNote("集計しました(\(change.result?.rows.count ?? 0) 行)。数値は DuckDB が計算したものです。")
                    return
                } catch {
                    previousError = error.localizedDescription
                    if attempt == 2 { throw error }
                }
            }
            change.status = .failed("集計の SQL を作れませんでした。聞き方を変えて、もう一度頼んでください。")
        } catch {
            change.status = .failed(error.localizedDescription)
        }
    }
}
