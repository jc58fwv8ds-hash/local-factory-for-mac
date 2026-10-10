import Foundation
import HarnessCore

enum ReplyDraftSelectionResult: Equatable {
    case applied
    case confirmationRequired
    case unavailable
}

extension WorkspaceStore {
    var replySuggestionContext: ReplySuggestionContext? {
        guard !isGenerating, !computerOperator.isBusy,
              let record = library.selectedRecord,
              record.project.operationCheckpoint == nil else { return nil }
        return ReplySuggestionContext(project: record.project)
    }

    func synchronizeReplySuggestions() {
        replySuggestions.synchronize(context: replySuggestionContext)
    }

    func generateReplySuggestions() {
        guard let context = replySuggestionContext else { return }
        replySuggestions.generate(for: context)
    }

    @discardableResult
    func useReplySuggestion(_ id: UUID, replacingDraft: Bool = false) -> ReplyDraftSelectionResult {
        guard let context = replySuggestionContext,
              let suggestion = replySuggestions.suggestion(id: id, context: context) else {
            return .unavailable
        }
        // Switching untouched suggestions is safe; replacing a person's edits needs confirmation.
        let hasPersonalDraft = !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !replySuggestions.suggestions.contains(where: { $0.instruction == instruction })
        if hasPersonalDraft && !replacingDraft { return .confirmationRequired }
        instruction = suggestion.instruction
        return .applied
    }
}
