import Foundation

public struct WorkItemDraft: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var status: WorkStatus

    public init(
        title: String = "",
        detail: String = "",
        status: WorkStatus = .pending
    ) {
        self.title = title
        self.detail = detail
        self.status = status
    }

    public init(item: WorkItem) {
        self.init(title: item.title, detail: item.detail, status: item.status)
    }

    public var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum ProjectWorkPlanError: LocalizedError, Equatable, Sendable {
    case emptyTitle
    case itemNotFound

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: "作業項目の名前を入力してください。"
        case .itemNotFound: "作業項目が見つかりません。"
        }
    }
}

public enum ProjectWorkPlanWorkflow {
    @discardableResult
    public static func add(
        _ draft: WorkItemDraft,
        to project: inout HarnessProject
    ) throws -> UUID {
        let normalized = try normalized(draft)
        let item = WorkItem(
            title: normalized.title,
            detail: normalized.detail,
            status: normalized.status
        )
        project.workItems.append(item)
        CreationCompletionPolicy.invalidateValidationEvidence(in: &project)
        RunCoordinatorWorkflow.reconcileWorkPlan(in: &project)
        record(
            title: "制作計画へ追加しました",
            detail: item.title,
            in: &project
        )
        return item.id
    }

    public static func update(
        _ id: UUID,
        from draft: WorkItemDraft,
        in project: inout HarnessProject
    ) throws {
        let normalized = try normalized(draft)
        guard let index = project.workItems.firstIndex(where: { $0.id == id }) else {
            throw ProjectWorkPlanError.itemNotFound
        }
        guard project.workItems[index].title != normalized.title
                || project.workItems[index].detail != normalized.detail
                || project.workItems[index].status != normalized.status else { return }

        if project.workItems[index].title != normalized.title
            || project.workItems[index].detail != normalized.detail {
            project.workItems[index].responseToMessageID = nil
        }
        project.workItems[index].title = normalized.title
        project.workItems[index].detail = normalized.detail
        project.workItems[index].status = normalized.status
        if normalized.status == .active {
            project.currentActivity = normalized.title
        }
        CreationCompletionPolicy.invalidateValidationEvidence(in: &project)
        RunCoordinatorWorkflow.reconcileWorkPlan(in: &project)
        record(
            title: "制作計画を更新しました",
            detail: normalized.title,
            in: &project
        )
    }

    public static func setStatus(
        _ status: WorkStatus,
        for id: UUID,
        in project: inout HarnessProject
    ) throws {
        guard let item = project.workItems.first(where: { $0.id == id }) else {
            throw ProjectWorkPlanError.itemNotFound
        }
        try update(
            id,
            from: WorkItemDraft(title: item.title, detail: item.detail, status: status),
            in: &project
        )
    }

    public static func move(
        _ id: UUID,
        by offset: Int,
        in project: inout HarnessProject
    ) throws {
        guard let sourceIndex = project.workItems.firstIndex(where: { $0.id == id }) else {
            throw ProjectWorkPlanError.itemNotFound
        }
        let destinationIndex = sourceIndex + offset
        guard project.workItems.indices.contains(destinationIndex) else { return }

        let item = project.workItems.remove(at: sourceIndex)
        project.workItems.insert(item, at: destinationIndex)
        record(
            title: "制作計画を並べ替えました",
            detail: item.title,
            in: &project
        )
    }

    public static func remove(
        _ id: UUID,
        from project: inout HarnessProject
    ) throws {
        guard let index = project.workItems.firstIndex(where: { $0.id == id }) else {
            throw ProjectWorkPlanError.itemNotFound
        }
        let item = project.workItems.remove(at: index)
        CreationCompletionPolicy.invalidateValidationEvidence(in: &project)
        RunCoordinatorWorkflow.reconcileWorkPlan(in: &project)
        record(
            title: "制作計画から削除しました",
            detail: item.title,
            in: &project
        )
    }

    private static func normalized(_ draft: WorkItemDraft) throws -> WorkItemDraft {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ProjectWorkPlanError.emptyTitle }
        return WorkItemDraft(
            title: title,
            detail: draft.detail.trimmingCharacters(in: .whitespacesAndNewlines),
            status: draft.status
        )
    }

    private static func record(
        title: String,
        detail: String,
        in project: inout HarnessProject
    ) {
        project.activity.insert(
            ActivityEvent(title: title, detail: detail, kind: .change),
            at: 0
        )
    }
}
