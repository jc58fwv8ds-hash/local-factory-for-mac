import Foundation

public enum WorkPlanReplanWorkflow {
    public static func apply(
        _ proposal: WorkPlanReplanProposal,
        to project: inout HarnessProject
    ) throws {
        guard WorkPlanFingerprint.make(project) == proposal.baselineFingerprint else {
            throw WorkPlanReplanError.planChanged
        }
        try validate(proposal, project: project)

        let scopedIDs = Set(proposal.scopedWorkItemIDs)
        guard let firstScopedIndex = project.workItems.firstIndex(where: {
            scopedIDs.contains($0.id)
        }) else {
            throw WorkPlanReplanError.planChanged
        }
        let currentByID = Dictionary(
            uniqueKeysWithValues: project.workItems.map { ($0.id, $0) }
        )
        let replanned = proposal.items.map { proposed -> WorkItem in
            if let existingID = proposed.existingWorkItemID,
               let existing = currentByID[existingID] {
                return existing
            }
            return WorkItem(
                id: proposed.id,
                title: proposed.title,
                detail: proposed.detail,
                status: .pending
            )
        }
        let insertionIndex = project.workItems[..<firstScopedIndex]
            .count(where: { !scopedIDs.contains($0.id) })
        project.workItems.removeAll { scopedIDs.contains($0.id) }
        project.workItems.insert(contentsOf: replanned, at: insertionIndex)
        CreationCompletionPolicy.invalidateValidationEvidence(in: &project)
        RunCoordinatorWorkflow.reconcileWorkPlan(in: &project)
        project.currentActivity = "確認した再計画案を制作計画へ反映しました"
        project.activity.insert(
            ActivityEvent(
                title: "制作計画の見直し案を採用しました",
                detail: String(proposal.summary.prefix(180)),
                kind: .change
            ),
            at: 0
        )
    }

    private static func validate(
        _ proposal: WorkPlanReplanProposal,
        project: HarnessProject
    ) throws {
        let scopedIDs = Set(proposal.scopedWorkItemIDs)
        let existingIDs = proposal.items.compactMap(\.existingWorkItemID)
        guard existingIDs.count == Set(existingIDs).count else {
            throw WorkPlanReplanError.duplicateReference
        }
        guard Set(existingIDs) == scopedIDs,
              scopedIDs.allSatisfy({ id in
                  project.workItems.contains {
                      $0.id == id && $0.responseToMessageID == nil && $0.status != .completed
                  }
              }) else {
            throw WorkPlanReplanError.missingExistingItem
        }
        guard proposal.newItemCount <= WorkPlanReplanProposal.maximumNewItems else {
            throw WorkPlanReplanError.tooManyNewItems
        }
        guard existingIDs.count + proposal.newItemCount
                <= WorkPlanReplanContext.maximumExistingItems else {
            throw WorkPlanReplanError.tooManyTotalItems
        }
        if let pinnedID = project.runCoordinator.currentWorkItemID,
           scopedIDs.contains(pinnedID),
           proposal.items.first?.existingWorkItemID != pinnedID {
            throw WorkPlanReplanError.pinnedItemMoved
        }
        guard !proposal.summary.isEmpty,
              proposal.summary.count <= WorkPlanReplanProposal.maximumSummaryCharacters else {
            throw WorkPlanReplanError.invalidSummary
        }
        guard proposal.uncertainties.count <= WorkPlanReplanProposal.maximumUncertainties,
              proposal.uncertainties.allSatisfy({
                  !$0.isEmpty
                      && $0.count <= WorkPlanReplanProposal.maximumUncertaintyCharacters
              }) else {
            throw WorkPlanReplanError.invalidUncertainties
        }
        for item in proposal.items {
            guard item.isNew else { continue }
            guard !item.title.isEmpty,
                  !item.title.contains(where: \.isNewline),
                  item.title.count <= WorkPlanReplanProposal.maximumTitleCharacters else {
                throw WorkPlanReplanError.invalidTitle
            }
            guard item.detail.count <= WorkPlanReplanProposal.maximumDetailCharacters else {
                throw WorkPlanReplanError.invalidDetail
            }
        }
    }
}
