import Foundation

/// Keeps response tracking separate from the production item discussed by the model.
enum ProjectInstructionAcceptance {
    private static let responseTitle = "AIの提案を確認"

    static func accept(
        instruction: String,
        proposedWorkItemID: UUID,
        origin: ConversationOrigin,
        visualAttachments: [VisualAttachmentDescriptor],
        in project: inout HarnessProject
    ) -> UUID {
        let previousMessage = ProjectInstructionContext.userMessages(in: project).last
        let reusableIndex: Int?
        if ContinuationInstruction.matches(instruction), let previousMessage {
            // Only reuse a response record we created and the user has not renamed or edited.
            reusableIndex = project.workItems.firstIndex {
                $0.responseToMessageID == previousMessage.id
                    && $0.title == responseTitle && $0.detail == previousMessage.content
            }
        } else {
            reusableIndex = nil
        }
        let message = ConversationMessage(
            role: .user,
            content: instruction,
            origin: origin,
            visualAttachments: visualAttachments
        )
        let status: WorkStatus = project.selectedModel == nil ? .needsAttention : .active
        let workItemID: UUID
        if let reusableIndex {
            workItemID = project.workItems[reusableIndex].id
            project.workItems[reusableIndex].detail = instruction
            project.workItems[reusableIndex].status = status
            project.workItems[reusableIndex].responseToMessageID = message.id
        } else {
            workItemID = proposedWorkItemID
            project.workItems.insert(
                WorkItem(
                    id: workItemID,
                    title: responseTitle,
                    detail: instruction,
                    status: status,
                    responseToMessageID: message.id
                ),
                at: 0
            )
        }
        CreationLoopWorkflow.acceptedConsultation(in: &project)
        project.conversation.append(message)
        project.activity.insert(
            ActivityEvent(
                title: origin == .remoteUser ? "iPhoneから指示を受け付けました" : "指示を受け付けました",
                detail: instruction,
                kind: .instruction
            ),
            at: 0
        )
        project.currentActivity = project.selectedModel.map {
            "\($0.displayName)が指示を理解しています"
        } ?? "AIモデルの接続を待っています"
        return workItemID
    }
}
