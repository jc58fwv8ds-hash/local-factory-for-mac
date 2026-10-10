import Foundation
import HarnessCore

enum CreationLoopChecks {
    static func run() throws {
        try checkStateTransitions()
        try checkPersistenceMigration()
        try checkExternalReviewPacket()
        print("✓ Creation loops and external review handoff stay bounded and explicit")
    }

    private static func checkStateTransitions() throws {
        var localProject = HarnessProject.starter
        CreationLoopWorkflow.acceptedInstruction(in: &localProject)
        try expect(
            localProject.creationLoop.phase == .localModelWorking
                && localProject.creationLoop.iteration == 1
                && localProject.stage == .build
                && localProject.progress == 0.35,
            "A first instruction did not start the local creation loop"
        )
        CreationLoopWorkflow.startedValidation(in: &localProject)
        CreationLoopWorkflow.completedValidation(
            succeeded: false,
            in: &localProject
        )
        try expect(
            localProject.creationLoop.phase == .awaitingHarnessReview
                && localProject.creationLoop.lastValidationSucceeded == false
                && localProject.stage == .test
                && localProject.progress == 0.75,
            "Local validation did not route to Harness review"
        )

        CreationLoopWorkflow.select(reviewMode: .chatGPTAssisted, in: &localProject)
        try expect(
            localProject.creationLoop.phase == .awaitingExternalReview,
            "Changing modes did not route a pending review to ChatGPT handoff"
        )
        CreationLoopWorkflow.importedExternalReview(
            response: "## 現状\n失敗\n## 修正案\n境界を分離"
                + String(
                    repeating: "x",
                    count: CreationLoopWorkflow.maximumImportedReviewCharacters
                ),
            in: &localProject
        )
        try expect(
            localProject.creationLoop.phase == .awaitingUserDecision
                && localProject.conversation.last?.modelName == "ChatGPTレビュー"
                && localProject.conversation.last?.origin == .externalReview
                && localProject.conversation.last?.content.count
                    == CreationLoopWorkflow.maximumImportedReviewCharacters,
            "Imported review did not return control to the user"
        )
        CreationLoopWorkflow.acceptedInstruction(in: &localProject)
        try expect(
            localProject.creationLoop.iteration == 2
                && localProject.creationLoop.lastValidationSucceeded == nil,
            "A revision instruction did not increment the loop or expire old validation evidence"
        )
        CreationLoopWorkflow.localProposalReady(in: &localProject)
        let blockedByWork = CreationLoopWorkflow.completed(in: &localProject)
        try expect(
            blockedByWork.blocker != nil
                && localProject.creationLoop.phase == .awaitingUserDecision
                && localProject.progress < 1,
            "Incomplete work was allowed to claim completion"
        )

        for index in localProject.workItems.indices
        where localProject.workItems[index].responseToMessageID == nil {
            localProject.workItems[index].status = .completed
        }
        let blockedWithoutValidation = CreationLoopWorkflow.completed(in: &localProject)
        try expect(
            blockedWithoutValidation.blocker == .validationRequired
                && localProject.creationLoop.phase == .awaitingUserDecision,
            "Completion was allowed without current validation evidence"
        )
        CreationLoopWorkflow.completedValidation(succeeded: true, in: &localProject)
        let completed = CreationLoopWorkflow.completed(in: &localProject)
        try expect(
            completed.isReady
                && localProject.creationLoop.phase == .completed
                && localProject.stage == .release
                && localProject.progress == 1,
            "Verified completed work did not finish progress consistently"
        )

        var failedProject = HarnessProject.starter
        failedProject.workItems.removeAll()
        CreationLoopWorkflow.startedValidation(in: &failedProject)
        CreationLoopWorkflow.completedValidation(succeeded: false, in: &failedProject)
        let blockedByFailure = CreationLoopWorkflow.completed(in: &failedProject)
        try expect(
            blockedByFailure.blocker == .validationFailed
                && failedProject.creationLoop.phase == .awaitingHarnessReview
                && failedProject.progress < 1,
            "Failed validation was allowed to claim completion"
        )

        var successfulProject = HarnessProject.starter
        CreationLoopWorkflow.startedValidation(in: &successfulProject)
        CreationLoopWorkflow.completedValidation(
            succeeded: true,
            in: &successfulProject
        )
        try expect(
            successfulProject.stage == .finish
                && successfulProject.progress == 0.90,
            "Successful validation did not advance to the finish milestone"
        )

        var fileEditProject = HarnessProject.starter
        ProjectFileEditInferenceWorkflow.started(
            instruction: "エラー処理を追加",
            in: &fileEditProject
        )
        try expect(
            fileEditProject.creationLoop.iteration == 1
                && fileEditProject.creationLoop.phase == .localModelWorking
                && fileEditProject.operationCheckpoint?.operation == .fileEditInference,
            "File-edit inference did not start a creation-loop iteration"
        )
        ProjectFileEditInferenceWorkflow.proposalReady(in: &fileEditProject)
        try expect(
            fileEditProject.creationLoop.phase == .awaitingUserDecision
                && fileEditProject.operationCheckpoint == nil,
            "A generated file proposal did not return control to the user"
        )
        ProjectFileEditInferenceWorkflow.failed(
            message: "runtime unavailable",
            in: &fileEditProject
        )
        try expect(
            fileEditProject.creationLoop.phase == .blocked
                && fileEditProject.activity.first?.kind == .warning,
            "File-edit inference failure did not block the loop consistently"
        )

        ProjectFileEditInferenceWorkflow.started(
            instruction: "中断確認",
            in: &fileEditProject
        )
        ProjectFileEditInferenceWorkflow.discardedInterruptedGeneration(
            in: &fileEditProject
        )
        try expect(
            fileEditProject.creationLoop.phase == .awaitingInstruction
                && fileEditProject.operationCheckpoint == nil,
            "Discarding interrupted file-edit inference left stale loop state"
        )
    }

    private static func checkPersistenceMigration() throws {
        let encoded = try JSONEncoder().encode(HarnessProject.starter)
        var object = try require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "creationLoop")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(HarnessProject.self, from: legacyData)
        try expect(
            decoded.creationLoop.reviewMode == .localOnly
                && decoded.creationLoop.phase == .awaitingInstruction
                && decoded.creationLoop.iteration == 0,
            "Older workspaces did not migrate to the local-only creation loop"
        )

        var inconsistentCompletion = HarnessProject.starter
        inconsistentCompletion.creationLoop.phase = .completed
        inconsistentCompletion.stage = .concept
        inconsistentCompletion.progress = 0.06
        let originalStatuses = inconsistentCompletion.workItems.map(\.status)
        let repairedCompletion = try JSONDecoder().decode(
            HarnessProject.self,
            from: JSONEncoder().encode(inconsistentCompletion)
        )
        try expect(
            repairedCompletion.stage == .release
                && repairedCompletion.progress == 1
                && repairedCompletion.workItems.map(\.status) == originalStatuses,
            "A legacy completion did not migrate progress without rewriting work evidence"
        )
    }

    private static func checkExternalReviewPacket() throws {
        let rootPath = "/Users/example/SecretProject"
        let source = SourceContextSnapshot(
            files: [
                SourceContextFile(
                    relativePath: "Sources/App.swift",
                    content: "let api_key = \"do-not-send\"\nlet safe = 42\n" + String(repeating: "x", count: 35_000),
                    wasTruncated: true
                )
            ],
            totalCharacters: 35_050,
            wasTruncated: true,
            skippedCandidateCount: 2
        )
        let check = ProjectValidationCheck(
            kind: .build,
            succeeded: false,
            exitCode: 1,
            output: "\(rootPath)/Sources/App.swift:1: error: failed",
            outputWasTruncated: false,
            duration: 0.2
        )
        let report = ProjectValidationReport(
            startedAt: .now,
            finishedAt: .now,
            checks: [check]
        )
        let packet = ExternalReviewPacketBuilder.make(
            project: .starter,
            rootPath: rootPath,
            report: report,
            analysis: nil,
            sourceContext: source
        )
        try expect(
            packet.content.count <= ExternalReviewPacketBuilder.maximumCharacters
                && !packet.content.contains(rootPath)
                && !packet.content.contains("do-not-send")
                && packet.redactedLineCount == 1
                && packet.wasTruncated,
            "External review packet leaked a path/credential or exceeded its bound"
        )
    }
}
