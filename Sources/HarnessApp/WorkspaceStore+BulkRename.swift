import Foundation
import HarnessCore

/// One bulk rename asked for in the chat (file operations stage 2, 2026-10-09): the model turns the request into a
/// RenameRule, the app expands and checks it, and the card shows the before → after table. Nothing is renamed before
/// "適用する", and "取り消す" restores every name.
@MainActor
@Observable
final class RenameChange: Identifiable {
    enum Status: Equatable { case running, ready, applied, failed(String), discarded }
    let id: UUID
    let instruction: String
    let folder: URL
    var status: Status = .running
    var rule: RenameRule?
    var plan: RenamePlan?

    init(id: UUID, instruction: String, folder: URL) {
        self.id = id
        self.instruction = instruction
        self.folder = folder
    }
}

enum BulkRenameIntent {
    /// "リネーム", or a name with a verb of changing it: 名前を変えて / 付け直して / そろえて / 統一して / 連番にして.
    static func isRenameRequest(_ text: String) -> Bool {
        if text.contains("リネーム") { return true }
        guard text.contains("名前") || text.contains("ファイル名") || text.contains("連番") else { return false }
        return ["変え", "変更", "付け", "そろえ", "揃え", "統一", "連番に", "直して", "にして"].contains { text.contains($0) }
    }

    /// The model writes a rule, never the names: it scales to any number of files and the names are checked by the app.
    static func prompt(instruction: String, folderName: String, files: [RenameFile]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let sample = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.prefix(40)
            .map { "\($0.name)\t作成 \(formatter.string(from: $0.created))\t更新 \(formatter.string(from: $0.modified))" }
        return """
        ユーザーはフォルダ「\(folderName)」(ファイル \(files.count) 件)のファイル名を一括で変えたい。依頼:
        \(instruction)

        ファイルの一部(名前・作成日時・更新日時):
        \(sample.joined(separator: "\n"))

        新しい名前を一つずつ書かずに、規則を JSON 一つで返してください。項目:
        "extensions": 対象の拡張子の配列(ドットなし、全部なら [])
        "nameContains": この文字を含む名前だけ(なければ null)
        "order": 連番の順 "name" / "created" / "modified"
        "find", "replace": 元の名前(拡張子を除く)に先に当てる正規表現と置換(不要なら null。置換では $1 で括弧の中を使える)
        "template": 新しい名前(拡張子を除く)。{name} 元の名前(find/replace の後)、{n} 連番、{n:3} 3 桁の連番、\
        {created:yyyyMMdd} 作成日、{modified:yyyy-MM-dd} 更新日、{parent} フォルダ名。拡張子は自動で残る
        "startNumber": 連番の開始(普通は 1)
        JSON だけを返してください。
        """
    }

    static func rule(from response: String) -> RenameRule? {
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}") else { return nil }
        return try? JSONDecoder().decode(RenameRule.self, from: Data(response[start...end].utf8))
    }
}

extension WorkspaceStore {
    func attachFolder(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        attachedFolder = url
    }

    /// A rename request with a folder attached becomes a rename card under the message.
    func submitRenameRequest(_ text: String) -> Bool {
        guard let folder = attachedFolder, let model = project.selectedModel else { return false }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        let message = ConversationMessage(role: .user, content: cleaned + "\n(フォルダ: \(folder.lastPathComponent))", origin: .user)
        library.updateSelectedProject { $0.conversation.append(message) }
        persist()
        let change = RenameChange(id: message.id, instruction: cleaned, folder: folder)
        renameChanges[message.id] = change
        Task { await runRenameChange(change, model: model) }
        return true
    }

    func runRenameChange(_ change: RenameChange, model: ModelSelection) async {
        let access = change.folder.startAccessingSecurityScopedResource()
        defer { if access { change.folder.stopAccessingSecurityScopedResource() } }
        do {
            let files = try BulkRenameExecutor.files(in: change.folder)
            let request = InferenceRequest(runtime: model.runtime, modelIdentifier: model.identifier,
                messages: [InferenceMessage(role: .user, content: BulkRenameIntent.prompt(
                    instruction: change.instruction, folderName: change.folder.lastPathComponent, files: files))],
                maximumOutputTokens: 600, temperature: 0)
            var response = ""
            for try await piece in await inferenceProvider.events(for: request) { response += piece }
            guard change.status == .running else { return }
            guard let rule = BulkRenameIntent.rule(from: response) else {
                change.status = .failed("名前の付け方の規則を読み取れませんでした。言い方を変えてもう一度頼んでください。")
                return
            }
            change.rule = rule
            change.plan = BulkRename.plan(rule, files: files, folderName: change.folder.lastPathComponent)
            change.status = .ready
            if let plan = change.plan {
                appendAssistantNote(plan.canApply
                    ? "名前の変更案ができました(\(plan.items.count) 件)。表を確かめて「適用する」を押すと反映します。"
                    : "名前の変更案に問題があります(\(plan.problems.first ?? "変わるファイルがありません"))。言い方を変えて頼んでください。")
            }
        } catch {
            guard change.status == .running else { return }
            change.status = .failed(error.localizedDescription)
        }
    }

    func applyRenameChange(_ change: RenameChange) {
        guard change.status == .ready, let plan = change.plan, plan.canApply else { return }
        let access = change.folder.startAccessingSecurityScopedResource()
        defer { if access { change.folder.stopAccessingSecurityScopedResource() } }
        do {
            try BulkRenameExecutor.apply(plan.items, in: change.folder)
            change.status = .applied
            appendAssistantNote("\(plan.items.count) 件の名前を変えました。カードの「取り消す」で元に戻せます。")
        } catch {
            change.status = .failed(error.localizedDescription)
        }
    }

    func revertRenameChange(_ change: RenameChange) {
        guard change.status == .applied, let plan = change.plan else { return }
        let access = change.folder.startAccessingSecurityScopedResource()
        defer { if access { change.folder.stopAccessingSecurityScopedResource() } }
        do {
            try BulkRenameExecutor.undo(plan.items, in: change.folder)
            change.status = .ready
            appendAssistantNote("名前の変更を取り消し、元の名前に戻しました。")
        } catch {
            presentNotice(error.localizedDescription, kind: .information)
        }
    }

    func discardRenameChange(_ change: RenameChange) {
        guard change.status == .ready || change.status == .running else { return }
        change.status = .discarded
    }
}
