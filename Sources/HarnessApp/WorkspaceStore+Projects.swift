import AppKit
import Foundation
import HarnessCore

extension WorkspaceStore {
    func selectProject(_ id: UUID) {
        guard library.selectedProjectID == id
            || allowInteraction(.changeSelectedProject) else { return }
        library.select(id)
        selectedSection = .home
        persist()
        monitorSourceIfNeeded(for: id)
    }

    @discardableResult
    func createProject(
        from draft: ProjectDraft,
        sourceLocation: String? = nil,
        origin: ProjectOrigin = .createdInHarness
    ) -> Bool {
        guard allowInteraction(.changeSelectedProject) else { return false }
        do {
            let record = try ProjectFactory().makeRecord(
                from: draft,
                origin: origin,
                sourceLocation: sourceLocation
            )
            library.add(record)
            selectedSection = .home
            persist(successMessage: "「\(record.project.name)」を作成しました")
            return true
        } catch {
            presentNotice(error.localizedDescription, kind: .error)
            return false
        }
    }

    func importProject(at url: URL) {
        if let existingRecord = library.sourceRecord(at: url) {
            guard library.selectedProjectID == existingRecord.id
                || allowInteraction(.changeSelectedProject) else { return }
            if existingRecord.lifecycle != .active {
                library.restore(existingRecord.id)
            }
            library.select(existingRecord.id)
            selectedSection = .home
            persist()
            presentNotice("登録済みの「\(existingRecord.project.name)」を開きました", kind: .information)
            inspectSource(for: existingRecord.id, announcesCompletion: false)
            return
        }

        guard allowInteraction(.changeSelectedProject) else { return }

        let draft = ProjectDraft(
            name: url.lastPathComponent,
            summary: "既存のソースフォルダから読み込んだプロジェクト",
            targets: ProjectSourceAnalyzer().inferredTargets(at: url)
        )
        let didCreate = createProject(
            from: draft,
            sourceLocation: url.standardizedFileURL.path,
            origin: .imported
        )
        if didCreate, let selectedProjectID = library.selectedProjectID {
            inspectSource(for: selectedProjectID, announcesCompletion: false)
        }
    }

    func updateProject(_ id: UUID, from draft: ProjectDraft) {
        guard library.updateProject(id, from: draft) else {
            presentNotice("プロジェクト情報を更新できませんでした", kind: .error)
            return
        }
        persist(successMessage: "プロジェクト情報を更新しました")
    }

    func archiveProject(_ id: UUID) {
        guard library.selectedProjectID != id
            || allowInteraction(.changeSelectedProject) else { return }
        library.archive(id)
        persist(successMessage: "プロジェクトをアーカイブしました")
    }

    func moveProjectToTrash(_ id: UUID) {
        guard library.selectedProjectID != id
            || allowInteraction(.changeSelectedProject) else { return }
        library.moveToTrash(id)
        persist(successMessage: "Local Factoryのゴミ箱へ移動しました。元ファイルは残っています")
    }

    /// Deleted from the sidebar: the next chat or project of this mode opens, not one of the other mode.
    /// The sidebar's 出力フォルダ (2026-11-05): where this chat's images and videos go, or the connected folder of a code project.
    func openOutputFolder() {
        if workspaceMode == .code, let path = library.selectedRecord?.sourceLocation {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        try? FileManager.default.createDirectory(at: Self.imageFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.imageFolder)
    }

    func deleteFromSidebar(_ id: UUID) {
        moveProjectToTrash(id)
        guard !selectedProjectIsInMode, let next = modeRecords.first else { return }
        library.select(next.id)
        persist()
    }

    func restoreProject(_ id: UUID) {
        guard library.selectedProjectID == id
            || allowInteraction(.changeSelectedProject) else { return }
        library.restore(id)
        persist(successMessage: "プロジェクトを制作中へ戻しました")
    }

    /// The sidebar trash's 完全に削除 (2026-11-04): the conversation and what it made in the app's own image folder. A connected
    /// source folder is the user's and stays.
    func deleteProjectCompletely(_ id: UUID) {
        guard library.trashedRecords.contains(where: { $0.id == id }),
              let record = library.records.first(where: { $0.id == id }) else { return }
        for file in Self.generatedFiles(in: record.project.conversation.map(\.content), folder: Self.imageFolder) {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("json"))
            try? FileManager.default.removeItem(at: GeneratedMedia.stepsFolder(of: file))
        }
        try? FileManager.default.removeItem(at: Self.imageFolder.appendingPathComponent("face-\(record.project.id.uuidString).png"))
        for message in record.project.conversation { imageChanges[message.id] = nil }
        ModelCallLog.remove(mentioning: record.project.conversation.map(\.content),
                            in: Self.imageFolder.deletingLastPathComponent().appendingPathComponent("model-calls"))
        removeProjectFromLibrary(id, message: "完全に削除しました")
        // The backup is the previous save, which still holds this chat: one more save replaces it.
        persist()
    }

    /// Every chat in `ids` removed for good, as 「完全に削除」 does one by one (2026-11-10: 「ゴミ箱を空にする」).
    func emptyTrash(_ ids: [UUID]) {
        for id in ids { deleteProjectCompletely(id) }
    }

    /// The images and videos a conversation names inside `folder` (「保存先: …/Images/abc-z-image-turbo.png」).
    nonisolated static func generatedFiles(in contents: [String], folder: URL) -> [URL] {
        let prefix = folder.path + "/"
        var names = Set<String>()
        for content in contents {
            for part in content.components(separatedBy: prefix).dropFirst() {
                let name = String(part.prefix { !$0.isWhitespace && $0 != "/" && !"。、)」".contains($0) })
                if name.hasSuffix(".png") || name.hasSuffix(".mp4") { names.insert(name) }
            }
        }
        return names.sorted().map { folder.appendingPathComponent($0) }
    }

    func removeProjectFromLibrary(_ id: UUID, message: String = "Local Factoryの一覧から削除しました。元ファイルは残っています") {
        guard library.selectedProjectID != id
            || allowInteraction(.changeSelectedProject) else { return }
        let sourceLocation = library.records.first(where: { $0.id == id })?.sourceLocation
        inspectingSourceProjectIDs.remove(id)
        sourceChangeSummaries.removeValue(forKey: id)
        library.removeFromLibrary(id)
        if let sourceLocation {
            Task { await sourceMonitor.forget(path: sourceLocation) }
        }
        persist(successMessage: message)
    }

    func inspectSource(
        for id: UUID,
        announcesCompletion: Bool = true,
        detectsChanges: Bool = true
    ) {
        guard !inspectingSourceProjectIDs.contains(id),
              let record = library.records.first(where: { $0.id == id }),
              let sourceLocation = record.sourceLocation else { return }

        inspectingSourceProjectIDs.insert(id)
        Task {
            let result = await sourceMonitor.inspect(
                path: sourceLocation,
                previousInspection: record.sourceInspection,
                detectsChanges: detectsChanges
            )
            inspectingSourceProjectIDs.remove(id)
            guard library.records.contains(where: { $0.id == id }) else { return }
            library.updateSourceInspection(result.inspection, for: id)
            sourceChangeSummaries[id] = result.change
            if let change = result.change {
                library.recordSourceChange(change, for: id)
                library.updateProject(id) { project in
                    RunCoordinatorWorkflow.observedSourceChange(in: &project)
                }
            }
            persist()

            if result.change != nil {
                presentNotice("ソースの変更を検出しました", kind: .information)
                return
            }
            guard announcesCompletion else { return }
            switch result.inspection.health {
            case .healthy:
                presentNotice("ソースフォルダを確認しました", kind: .success)
            case .limited:
                presentNotice("上限まで確認しました。診断結果は一部です", kind: .information)
            case .missing:
                presentNotice("ソースフォルダが見つかりません", kind: .error)
            case .unreadable:
                presentNotice("ソースフォルダを読み取れませんでした", kind: .error)
            }
        }
    }

    func connectSourceFolder(_ url: URL, to id: UUID) {
        if let existingRecord = library.sourceRecord(at: url), existingRecord.id != id {
            presentNotice(
                "このフォルダは「\(existingRecord.project.name)」へ接続済みです",
                kind: .error
            )
            return
        }
        guard library.connectSource(at: url.path, to: id) else {
            presentNotice("ソースフォルダを接続できませんでした", kind: .error)
            return
        }
        persist(successMessage: "ソースフォルダを接続しました")
        sourceChangeSummaries.removeValue(forKey: id)
        inspectSource(for: id, announcesCompletion: false, detectsChanges: false)
    }

    func disconnectSourceFolder(from id: UUID) {
        let sourceLocation = library.records.first(where: { $0.id == id })?.sourceLocation
        inspectingSourceProjectIDs.remove(id)
        sourceChangeSummaries.removeValue(forKey: id)
        guard library.disconnectSource(from: id) else {
            presentNotice("ソースフォルダの接続を解除できませんでした", kind: .error)
            return
        }
        if let sourceLocation {
            Task { await sourceMonitor.forget(path: sourceLocation) }
        }
        persist(successMessage: "接続を解除しました。元ファイルは変更していません")
    }

    func monitorSelectedSourceIfNeeded(minimumInterval: TimeInterval = 30) {
        guard let record = library.selectedRecord else { return }
        monitorSourceIfNeeded(for: record.id, minimumInterval: minimumInterval)
    }

    private func monitorSourceIfNeeded(
        for id: UUID,
        minimumInterval: TimeInterval = 30
    ) {
        guard let record = library.records.first(where: { $0.id == id }),
              record.sourceLocation != nil,
              !inspectingSourceProjectIDs.contains(id) else { return }
        if let scannedAt = record.sourceInspection?.scannedAt,
           Date().timeIntervalSince(scannedAt) < minimumInterval {
            return
        }
        inspectSource(
            for: id,
            announcesCompletion: false,
            detectsChanges: record.sourceInspection != nil
        )
    }
}
