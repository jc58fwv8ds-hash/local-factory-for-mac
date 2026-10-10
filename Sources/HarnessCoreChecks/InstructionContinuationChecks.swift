import Foundation
import HarnessCore

enum InstructionContinuationChecks {
    private static let model = ModelSelection(identifier: "fixture", displayName: "Fixture", runtime: .ollama)

    static func run() throws {
        try checkPhrases()
        try checkAcceptanceAndContext()
        try checkLegacyAndEditedItems()
        try checkMissingContext()
        print("✓ Continuations retain real task context, reuse response tracking, and preserve production evidence")
    }

    private static func checkPhrases() throws {
        for phrase in ["再開", "続けよ", "続けてちょ〜", "OKじゃあ進めよう〜", "再開して！", "tudukete", "お願い", "よろしくお願いします"] {
            try expect(ContinuationInstruction.matches(phrase), "Continuation was missed: \(phrase)")
        }
        for phrase in [
            "", "再開ボタンを追加して", "続けていいか教えて", "続けてではなく止めて",
            "今は再開しないで", "検索もお願い", "削除をお願い", "再開の意味は？",
            "Continueボタンを直して", "続けて、保存先を変更して", "続けようか？"
        ] {
            try expect(!ContinuationInstruction.matches(phrase), "Specific or negative request became a continuation: \(phrase)")
            var project = HarnessProject.starter
            project.conversation = [ConversationMessage(role: .user, content: phrase)]
            if !phrase.isEmpty {
                try expect(
                    ProjectInstructionContext.interpretation(for: project).contains("原文: \(phrase)"),
                    "A specific request lost its original meaning"
                )
            }
        }
    }

    private static func checkAcceptanceAndContext() throws {
        var project = HarnessProject.starter
        project.selectedModel = model
        let originalItems = project.workItems
        let originalProgress = project.progress
        let originalStage = project.stage
        let originalInstruction = "WatchからiPhoneへ記録を渡す流れを考えてね"
        let responseID = ProjectInferenceWorkflow.accept(
            instruction: originalInstruction, workItemID: UUID(), in: &project
        )
        ProjectInferenceWorkflow.complete(response: "転送の案を説明します。", model: model, workItemID: responseID, in: &project)
        for phrase in ["続けて", "再開", "続けよ"] {
            let acceptedID = ProjectInferenceWorkflow.accept(
                instruction: phrase, workItemID: UUID(), origin: .remoteUser, in: &project
            )
            try expect(acceptedID == responseID, "Continuation created a duplicate response item")
            ProjectOperationCheckpointWorkflow.started(.modelInference, referenceID: acceptedID, in: &project)
            let context = ProjectInstructionContext.interpretation(for: project)
            try expect(
                context.contains("次の候補: 端末間の役割を設計")
                    && context.contains(originalInstruction)
                    && !context.contains("次の候補: AIの提案を確認"),
                "A just-accepted continuation selected its own response record"
            )
            let restored = try JSONDecoder().decode(HarnessProject.self, from: JSONEncoder().encode(project))
            try expect(
                restored.workItems.first?.responseToMessageID == restored.conversation.last?.id
                    && ProjectInstructionContext.interpretation(for: restored) == context,
                "Continuation context or response reference was lost on restart"
            )
            ProjectInferenceWorkflow.complete(response: "続きの案です。", model: model, workItemID: acceptedID, in: &project)
            ProjectOperationCheckpointWorkflow.completed(.modelInference, in: &project)
        }
        try expect(
            project.workItems.count == originalItems.count + 1
                && project.workItems.filter { $0.id != responseID } == originalItems
                && project.progress == originalProgress && project.stage == originalStage
                && project.conversation.filter { $0.role == .user }.map(\.content)
                    == [originalInstruction, "続けて", "再開", "続けよ"],
            "Continuations changed production state or lost original user messages"
        )
        let newID = ProjectInferenceWorkflow.accept(
            instruction: "再開ボタンを追加して", workItemID: UUID(), in: &project
        )
        try expect(newID != responseID, "A new requirement reused the continuation response item")
    }

    private static func checkLegacyAndEditedItems() throws {
        var project = HarnessProject.starter
        let legacyItem = WorkItem(title: "新しい指示を実行", detail: "続けて", status: .active)
        project.workItems.insert(legacyItem, at: 0)
        ProjectInferenceWorkflow.accept(instruction: "続けて", workItemID: UUID(), in: &project)
        try expect(
            ProjectInstructionContext.interpretation(for: project).contains("次の候補: 端末間の役割を設計")
                && project.workItems.contains(legacyItem),
            "A legacy continuation record hid real work or was silently rewritten"
        )
        let data = try JSONEncoder().encode(legacyItem)
        var legacyJSON = try require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacyJSON.removeValue(forKey: "responseToMessageID")
        let restored = try JSONDecoder().decode(WorkItem.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        try expect(restored == legacyItem, "Old work items no longer decode")

        let editedID = try require(project.workItems.first?.id)
        try ProjectWorkPlanWorkflow.update(
            editedID,
            from: WorkItemDraft(title: "自分で名付けた作業", detail: "内容を保持", status: .pending),
            in: &project
        )
        let editedItem = try require(project.workItems.first)
        let nextID = ProjectInferenceWorkflow.accept(instruction: "続けて", workItemID: UUID(), in: &project)
        try expect(
            nextID != editedID && project.workItems.contains(editedItem),
            "Continuation overwrote a user-edited response item"
        )
    }

    private static func checkMissingContext() throws {
        var project = HarnessProject.starter
        project.workItems = []
        project.conversation = [
            ConversationMessage(role: .assistant, content: "秘密の別作業を開始", origin: .externalReview)
        ]
        let responseID = ProjectInferenceWorkflow.accept(instruction: "続けて", workItemID: UUID(), in: &project)
        let interpretation = ProjectInstructionContext.interpretation(for: project)
        try expect(
            interpretation.contains("未完了の制作項目は確認できません")
                && interpretation.contains("直前の具体的な指示はありません")
                && !interpretation.contains("秘密の別作業"),
            "Missing context was invented from a response or external review"
        )
        let nextID = ProjectInferenceWorkflow.accept(instruction: "続けて", workItemID: UUID(), in: &project)
        try expect(
            nextID == responseID && project.workItems.count == 1
                && project.workItems[0].status == .needsAttention,
            "Repeated model-less requests duplicated response tracking"
        )
    }
}
