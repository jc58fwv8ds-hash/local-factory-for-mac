import Foundation

public enum ProjectInstructionContext {
    public static func userMessages(in project: HarnessProject) -> [ConversationMessage] {
        project.conversation.filter {
            $0.role == .user && ($0.origin == .user || $0.origin == .remoteUser)
        }
    }

    public static func productionCandidates(in project: HarnessProject) -> [WorkItem] {
        project.workItems.filter {
            $0.responseToMessageID == nil
                && !ContinuationInstruction.matches($0.detail)
                && !(project.operationCheckpoint?.operation == .modelInference
                    && project.operationCheckpoint?.referenceID == $0.id)
        }
    }

    public static func interpretation(for project: HarnessProject) -> String {
        let messages = userMessages(in: project)
        let latest = messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !latest.isEmpty else {
            return "新しいユーザー指示はまだありません。勝手に作業完了を主張しないでください。"
        }
        guard ContinuationInstruction.matches(latest) else {
            return """
            ユーザーの原文を意味を落とさず扱ってください。専門用語が少なくても、目的・変更範囲・制約・完了条件へ内部で整理してください。
            原文: \(PromptReferenceText.excerpt(latest, maximumCharacters: 4_000))
            """
        }

        let previousInstruction = messages.dropLast().last {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !ContinuationInstruction.matches($0.content)
        }?.content
        let candidates = productionCandidates(in: project)
        let nextItem = candidates.first { $0.status == .active }
            ?? candidates.first { $0.status == .needsAttention }
            ?? candidates.first { $0.status == .pending }
        let prior = previousInstruction.map {
            let excerpt = PromptReferenceText.excerpt($0, maximumCharacters: 4_000)
            return "直前の具体的なユーザー指示（継続の文脈）: \(excerpt)"
        } ?? "直前の具体的な指示はありません。"
        let next = nextItem.map {
            "次の候補: \($0.title) — \($0.detail)"
        } ?? "未完了の制作項目は確認できません。完成済みと決めつけず、直前の指示や現在の状態から安全な次の一歩を1つ提案してください。"
        return """
        「\(latest)」は短い継続指示です。継続指示そのものを新しい制作作業にせず、元の依頼の範囲で続けてください。
        \(prior)
        \(next)
        元の依頼と候補が食い違う場合は、候補を勝手に実行せず質問を1つに絞ってください。
        承認待ち・中断状態を飛ばさず、提案を返しただけで制作や検証が完了したとは扱わないでください。
        """
    }
}
