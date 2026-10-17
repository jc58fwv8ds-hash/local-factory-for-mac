import Foundation
import HarnessCore

/// One app-install request from the chat (backlog #49): the card lists Homebrew casks; nothing is downloaded until the
/// user picks one and presses インストールする.
@MainActor
@Observable
final class AppInstallChange: Identifiable {
    enum Status: Equatable { case searching, ready, installing, installed([AppInstaller.Verification]), failed(String), discarded }
    let id: UUID
    let query: String
    var status: Status = .searching
    var candidates: [AppInstaller.Candidate] = []
    var selected: String?

    init(id: UUID, query: String) {
        self.id = id
        self.query = query
    }
}

extension WorkspaceStore {
    /// 「◯◯をインストールして」 becomes an install card; any other message returns false.
    func submitAppInstall(_ text: String) -> Bool {
        guard let query = AppInstaller.query(from: text) else { return false }
        let message = ConversationMessage(role: .user, content: text, origin: .user)
        library.updateSelectedProject { $0.conversation.append(message) }
        persist()
        let change = AppInstallChange(id: message.id, query: query)
        appInstallChanges[message.id] = change
        let model = project.selectedModel
        Task { await searchApps(change, model: model) }
        return true
    }

    func searchApps(_ change: AppInstallChange, model: ModelSelection?) async {
        let original = change.query
        var found = (try? await Task.detached { try AppInstaller.search(original) }.value) ?? []
        // A name in Japanese (「ファイアフォックス」) rarely matches a cask: ask the model for the product's English name once.
        if found.isEmpty, original.unicodeScalars.contains(where: { !$0.isASCII }), let model {
            let request = InferenceRequest(runtime: model.runtime, modelIdentifier: model.identifier, messages: [
                InferenceMessage(role: .user, content: "Mac アプリ「\(original)」の英語の正式な製品名だけを 1 行で答えてください。分からなければ「不明」。")],
                maximumOutputTokens: 30, temperature: 0)
            var answer = ""
            do { for try await piece in await inferenceProvider.events(for: request) { answer += piece } } catch { answer = "" }
            let english = answer.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "「」\"'。")))
            if !english.isEmpty, english != "不明", english.unicodeScalars.allSatisfy(\.isASCII), english.count < 60 {
                found = (try? await Task.detached { try AppInstaller.search(english) }.value) ?? []
            }
        }
        guard !found.isEmpty else {
            change.status = .failed(AppInstaller.brew == nil ? AppInstaller.Failure.noHomebrew.localizedDescription
                                    : AppInstaller.Failure.notFound(change.query).localizedDescription)
            return
        }
        change.candidates = found
        change.selected = found.first?.token
        change.status = .ready
        appendAssistantNote("「\(change.query)」の候補を \(found.count) 件見つけました。カードで中身を確かめて、入れるものを選んで「インストールする」を押してください。押すまで何もダウンロードしません。")
    }

    func installApp(_ change: AppInstallChange) async {
        guard change.status == .ready, let token = change.selected,
              let candidate = change.candidates.first(where: { $0.token == token }) else { return }
        change.status = .installing
        do {
            _ = try await Task.detached { try AppInstaller.install(token) }.value
            let checks = await Task.detached {
                candidate.appNames.map { AppInstaller.verify(appAt: "/Applications/" + $0) }
            }.value
            change.status = .installed(checks)
            let ok = checks.allSatisfy { $0.signed && $0.notarized }
            appendAssistantNote("「\(candidate.name)」を入れました。" + (checks.isEmpty ? "" : ok
                ? "署名と Apple の公証を確かめました。"
                : "署名または公証を確かめられなかったものがあります。カードの結果を見て、心配なら使う前に削除してください。"))
        } catch {
            change.status = .failed(error.localizedDescription)
        }
    }

    func discardAppInstall(_ change: AppInstallChange) {
        if change.status == .ready || change.status == .searching { change.status = .discarded }
    }
}
