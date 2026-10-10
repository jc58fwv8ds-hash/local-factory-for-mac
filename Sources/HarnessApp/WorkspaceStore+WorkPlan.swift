import Foundation
import HarnessCore

extension WorkspaceStore {
    func addWorkItem(_ draft: WorkItemDraft) -> Bool {
        performWorkPlanMutation(successMessage: "制作計画へ追加しました") { project in
            try ProjectWorkPlanWorkflow.add(draft, to: &project)
        }
    }

    func updateWorkItem(_ id: UUID, from draft: WorkItemDraft) -> Bool {
        performWorkPlanMutation(successMessage: "制作計画を更新しました") { project in
            try ProjectWorkPlanWorkflow.update(id, from: draft, in: &project)
        }
    }

    func setWorkItemStatus(_ status: WorkStatus, for id: UUID) {
        _ = performWorkPlanMutation(successMessage: nil) { project in
            try ProjectWorkPlanWorkflow.setStatus(status, for: id, in: &project)
        }
    }

    func moveWorkItem(_ id: UUID, by offset: Int) {
        _ = performWorkPlanMutation(successMessage: nil) { project in
            try ProjectWorkPlanWorkflow.move(id, by: offset, in: &project)
        }
    }

    func removeWorkItem(_ id: UUID) {
        _ = performWorkPlanMutation(successMessage: "制作計画から削除しました") { project in
            try ProjectWorkPlanWorkflow.remove(id, from: &project)
        }
    }

    @discardableResult
    func applyWorkPlanReplan(
        _ proposal: WorkPlanReplanProposal,
        projectID: UUID
    ) -> Bool {
        do {
            guard try library.mutateProject(projectID, { project in
                try WorkPlanReplanWorkflow.apply(proposal, to: &project)
            }) else {
                presentNotice("プロジェクトを確認できませんでした", kind: .error)
                return false
            }
            persist(successMessage: "確認した見直し案を制作計画へ反映しました")
            return true
        } catch {
            presentNotice(error.localizedDescription, kind: .error)
            return false
        }
    }

    @discardableResult
    private func performWorkPlanMutation(
        successMessage: String?,
        mutation: (inout HarnessProject) throws -> Void
    ) -> Bool {
        guard let projectID = library.selectedProjectID else {
            presentNotice("プロジェクトが選択されていません", kind: .error)
            return false
        }

        do {
            guard try library.mutateProject(projectID, mutation) else {
                presentNotice("制作計画を更新できませんでした", kind: .error)
                return false
            }
            persist(successMessage: successMessage)
            return true
        } catch {
            presentNotice(error.localizedDescription, kind: .error)
            return false
        }
    }
}
