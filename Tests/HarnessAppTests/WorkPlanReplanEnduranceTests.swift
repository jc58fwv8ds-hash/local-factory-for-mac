import Foundation
import HarnessCore
import Testing

struct WorkPlanReplanEnduranceTests {
    @Test func twelveItemPlanCannotGrowPastTheNextReplanLimit() throws {
        let project = makeProject(count: 12)
        let context = try makeContext(project)
        #expect(context.availableNewItemCount == 0)
        #expect(
            WorkPlanReplanPromptBuilder.messages(context: context)
                .map(\.content).joined().contains("新しい項目は追加せず")
        )

        let response = try responseJSON(context: context, newItemCount: 1)
        #expect(throws: WorkPlanReplanError.tooManyTotalItems) {
            try WorkPlanReplanResponseParser.proposal(from: response, context: context)
        }
    }

    @Test func remainingCapacityIsStricterThanThePerProposalMaximum() throws {
        let context = try makeContext(makeProject(count: 10))
        #expect(context.availableNewItemCount == 2)

        let response = try responseJSON(context: context, newItemCount: 3)
        #expect(throws: WorkPlanReplanError.tooManyTotalItems) {
            try WorkPlanReplanResponseParser.proposal(from: response, context: context)
        }
    }

    @Test func repeatedReplanAndRestartNeverLosesOrRewritesWork() throws {
        var project = makeProject(count: 9)
        var knownCriteria = Dictionary(
            uniqueKeysWithValues: project.workItems.map { ($0.id, ($0.title, $0.detail)) }
        )

        for cycle in 0..<20 {
            let context = try makeContext(project)
            let additionCount = context.availableNewItemCount > 0 ? 1 : 0
            var proposed = context.items.map {
                WorkPlanReplanItem(
                    existingWorkItemID: $0.workItemID,
                    title: "AIが変えた名前",
                    detail: "AIが変えた条件"
                )
            }
            if proposed.count > 2 {
                proposed = [proposed[0]] + proposed.dropFirst().reversed()
            }
            if additionCount == 1 {
                proposed.append(
                    WorkPlanReplanItem(
                        existingWorkItemID: nil,
                        title: "追加確認\(cycle + 1)",
                        detail: "再計画後に確認する"
                    )
                )
            }
            let proposal = WorkPlanReplanProposal(
                baselineFingerprint: context.baselineFingerprint,
                scopedWorkItemIDs: context.items.map(\.workItemID),
                summary: "\(cycle + 1)回目の見直し",
                uncertainties: cycle.isMultiple(of: 2) ? [] : ["環境要因は未確定"],
                items: proposed
            )

            try WorkPlanReplanWorkflow.apply(proposal, to: &project)
            for item in project.workItems where knownCriteria[item.id] == nil {
                knownCriteria[item.id] = (item.title, item.detail)
            }
            project = try JSONDecoder().decode(
                HarnessProject.self,
                from: JSONEncoder().encode(project)
            )

            let unfinished = ProjectInstructionContext.productionCandidates(in: project)
                .filter { $0.status != .completed }
            #expect(unfinished.count <= WorkPlanReplanContext.maximumExistingItems)
            #expect(Set(unfinished.map(\.id)) == Set(knownCriteria.keys))
            for item in unfinished {
                #expect(item.title == knownCriteria[item.id]?.0)
                #expect(item.detail == knownCriteria[item.id]?.1)
            }
            #expect(project.runCoordinator.currentWorkItemID == unfinished.first?.id)
        }

        #expect(project.workItems.count == 12)
    }

    private func makeProject(count: Int) -> HarnessProject {
        let items = (1...count).map { index in
            WorkItem(
                title: "項目\(index)",
                detail: "完了条件\(index)",
                status: index == 1 ? .active : .pending
            )
        }
        return HarnessProject(
            name: "再計画耐久テスト",
            summary: "",
            targets: [.macOS],
            stage: .test,
            progress: 0.6,
            currentActivity: "検証失敗",
            workItems: items,
            activity: [],
            creationLoop: CreationLoopState(phase: .awaitingUserDecision),
            runCoordinator: RunCoordinatorState(
                phase: .awaitingRepair,
                currentWorkItemID: items.first?.id,
                attemptedCycleCount: 1
            )
        )
    }

    private func makeContext(_ project: HarnessProject) throws -> WorkPlanReplanContext {
        try WorkPlanReplanContextBuilder.make(
            project: project,
            report: ProjectValidationReport(
                startedAt: Date(timeIntervalSince1970: 1),
                finishedAt: Date(timeIntervalSince1970: 2),
                checks: [
                    ProjectValidationCheck(
                        kind: .test,
                        succeeded: false,
                        exitCode: 1,
                        output: "failed",
                        outputWasTruncated: false,
                        duration: 1
                    )
                ]
            ),
            analysis: nil
        )
    }

    private func responseJSON(
        context: WorkPlanReplanContext,
        newItemCount: Int
    ) throws -> String {
        var items: [[String: Any]] = context.items.map {
            ["reference": $0.reference, "title": $0.title, "detail": $0.detail]
        }
        for index in 0..<newItemCount {
            items.append([
                "reference": NSNull(),
                "title": "追加\(index + 1)",
                "detail": "確認を追加"
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "summary": "見直し",
            "uncertainties": [],
            "items": items
        ])
        return try #require(String(data: data, encoding: .utf8))
    }
}
