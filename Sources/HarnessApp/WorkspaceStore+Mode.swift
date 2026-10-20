import Foundation
import HarnessCore

/// Chat and code modes (2026-10-19, the user's request). Chat: conversation, writing, images and video, with the models
/// the user picked per purpose. Code: building apps (projects with sources, code changes, Xcode, devices); the purpose
/// models are not offered there and messages may become code changes. Each mode lists only its own projects.
enum WorkspaceMode: String, CaseIterable, Identifiable {
    case chat, code
    var id: String { rawValue }
    var title: String { self == .chat ? "チャット" : "コード" }
    var symbol: String { self == .chat ? "bubble.left.and.text.bubble.right" : "hammer" }
    var kind: ProjectKind { self == .chat ? .chat : .code }

    static let key = "harness.workspaceMode"
    static func lastProjectKey(_ mode: WorkspaceMode) -> String { "harness.workspaceMode.last.\(mode.rawValue)" }
    static var saved: WorkspaceMode { WorkspaceMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .code }
}

extension WorkspaceStore {
    /// The projects of the current mode, most recently opened first.
    var modeRecords: [ProjectRecord] { library.activeRecords(of: workspaceMode.kind) }

    /// True when the selected project belongs to the current mode (otherwise the mode's empty screen is shown).
    var selectedProjectIsInMode: Bool { library.selectedRecord?.effectiveKind == workspaceMode.kind }

    /// The purposes the composer offers: all of them in chat (video once a video model is listed), conversation in code.
    var availablePurposes: [ComposerPurpose] {
        guard workspaceMode == .chat else { return [.conversation] }
        return ComposerPurpose.allCases.filter { $0 != .video || !purposeSettings.catalog.options(for: .video).isEmpty }
    }

    func switchMode(_ mode: WorkspaceMode) {
        guard mode != workspaceMode, allowInteraction(.changeSelectedProject) else { return }
        if let current = library.selectedRecord, current.effectiveKind == workspaceMode.kind {
            UserDefaults.standard.set(current.id.uuidString, forKey: WorkspaceMode.lastProjectKey(workspaceMode))
        }
        workspaceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: WorkspaceMode.key)
        composerPurpose = .conversation
        selectedSection = .home
        let last = UserDefaults.standard.string(forKey: WorkspaceMode.lastProjectKey(mode)).flatMap(UUID.init(uuidString:))
        if let target = modeRecords.first(where: { $0.id == last }) ?? modeRecords.first {
            library.select(target.id)
            persist()
        }
    }

    /// A new chat: no source folder, the current model, selected at once.
    func startNewChat() {
        guard allowInteraction(.changeSelectedProject) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日 H:mm"
        do {
            var record = try ProjectFactory().makeRecord(
                from: ProjectDraft(name: "チャット \(formatter.string(from: .now))", summary: "チャット"),
                origin: .createdInHarness, sourceLocation: nil)
            record.kind = .chat
            record.project.selectedModel = project.selectedModel
            library.add(record)
            selectedSection = .home
            persist()
        } catch {
            presentNotice(error.localizedDescription, kind: .error)
        }
    }
}
