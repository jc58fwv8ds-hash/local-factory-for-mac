import Foundation
import HarnessCore

/// Ephemeral diagnostics for one committed answer. Never saved as conversation or test evidence.
struct ConversationPerformance: Equatable {
    let projectID: UUID
    let responseID: UUID
    let attempts: [InferenceResponseTiming]

    func belongs(to project: HarnessProject) -> Bool {
        project.id == projectID && project.conversation.last?.id == responseID
            && project.conversation.last?.origin == .localModel
    }
}

extension WorkspaceStore {
    var visibleConversationPerformance: ConversationPerformance? {
        guard !isGeneratingSelectedProject,
              let result = lastConversationPerformance,
              result.belongs(to: project) else { return nil }
        return result
    }
}
