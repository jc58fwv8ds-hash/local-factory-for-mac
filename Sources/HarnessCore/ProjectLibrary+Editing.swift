import Foundation

public extension ProjectLibrary {
    mutating func updateProject(_ project: HarnessProject) {
        guard let index = records.firstIndex(where: { $0.id == project.id }) else { return }
        records[index].project = project
        records[index].updatedAt = .now
    }

    mutating func updateSelectedProject(
        _ update: (inout HarnessProject) -> Void
    ) {
        guard let selectedProjectID,
              let index = records.firstIndex(where: { $0.id == selectedProjectID }) else { return }
        update(&records[index].project)
        records[index].updatedAt = .now
    }

    mutating func updateProject(
        _ id: UUID,
        _ update: (inout HarnessProject) -> Void
    ) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        update(&records[index].project)
        records[index].updatedAt = .now
    }

    @discardableResult
    mutating func mutateProject(
        _ id: UUID,
        _ mutation: (inout HarnessProject) throws -> Void
    ) rethrows -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        try mutation(&records[index].project)
        records[index].updatedAt = .now
        return true
    }

    @discardableResult
    mutating func updateProject(_ id: UUID, from draft: ProjectDraft) -> Bool {
        let cleanedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty,
              let index = records.firstIndex(where: { $0.id == id }) else { return false }

        let oldProject = records[index].project
        let selectedTargets = Set(draft.targets)
        records[index].project.name = cleanedName
        records[index].project.summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        records[index].project.targets = {
            let ordered = TargetPlatform.allCases.filter(selectedTargets.contains)
            return ordered.isEmpty ? [.macOS] : ordered
        }()
        records[index].project.stage = draft.stage
        records[index].updatedAt = .now

        if records[index].project != oldProject {
            records[index].project.activity.insert(
                ActivityEvent(
                    title: "プロジェクト情報を更新しました",
                    detail: "名前、説明、対象、制作ステージを確認しました",
                    kind: .change
                ),
                at: 0
            )
        }
        return true
    }

    mutating func rename(_ id: UUID, to newName: String) {
        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].project.name = cleaned
        records[index].updatedAt = .now
    }

    mutating func updateSourceInspection(_ inspection: SourceInspection, for id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].sourceInspection = inspection
        records[index].updatedAt = .now
    }

    mutating func recordSourceChange(_ change: SourceChangeSummary, for id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].project.activity.insert(
            ActivityEvent(
                title: "ソースの変更を検出しました",
                detail: change.summaryText,
                kind: .information
            ),
            at: 0
        )
        records[index].updatedAt = .now
    }

    @discardableResult
    mutating func connectSource(at path: String, to id: UUID) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !records.contains(where: { record in
            guard record.id != id, let existingPath = record.sourceLocation else { return false }
            return URL(fileURLWithPath: existingPath).standardizedFileURL.path == standardizedPath
        }) else { return false }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        records[index].sourceLocation = standardizedPath
        records[index].sourceInspection = nil
        records[index].updatedAt = .now
        records[index].project.activity.insert(
            ActivityEvent(
                title: "ソースフォルダを接続しました",
                detail: records[index].sourceLocation ?? path,
                kind: .information
            ),
            at: 0
        )
        return true
    }

    @discardableResult
    mutating func disconnectSource(from id: UUID) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }),
              records[index].sourceLocation != nil else { return false }
        records[index].sourceLocation = nil
        records[index].sourceInspection = nil
        records[index].updatedAt = .now
        records[index].project.activity.insert(
            ActivityEvent(
                title: "ソースフォルダの接続を解除しました",
                detail: "Local Factory内の参照だけを解除しました。元ファイルは残っています",
                kind: .information
            ),
            at: 0
        )
        return true
    }
}
