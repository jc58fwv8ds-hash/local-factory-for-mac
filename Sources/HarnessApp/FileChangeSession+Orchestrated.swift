import Foundation
import HarnessCore

extension FileChangeSession {
    /// Flag-on path: the orchestrated run produces the content; the proposal goes to the same review and
    /// approval step as the legacy path, so nothing reaches the project before the user applies it.
    func askOrchestrator(_ orchestrator: any OrchestratedEditing, document: EditableSourceDocument,
                         instruction: String, model: ModelSelection) {
        isGenerating = true
        errorMessage = nil
        proposal = nil
        orchestratedOutcome = nil
        onGenerationEvent(.started(instruction))
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await orchestrator.proposeEdit(rootPath: rootPath, relativePath: document.relativePath,
                                                                 instruction: instruction, model: model)
                try Task.checkCancellation()
                var proposals: [FileChangeProposal] = []
                for change in outcome.changes {
                    if let original = change.original {
                        let current = EditableSourceDocument(relativePath: change.relativePath, content: original)
                        proposals.append(try await editor.makeProposal(document: current, proposedContent: change.proposed))
                    } else {
                        proposals.append(try await editor.makeCreationProposal(rootPath: rootPath,
                            relativePath: change.relativePath, proposedContent: change.proposed))
                    }
                }
                // The review centers on the selected file; when the change left it untouched, on the first changed file.
                guard let primary = proposals.first(where: { $0.relativePath == document.relativePath && $0.operation == .update })
                        ?? proposals.first(where: { $0.operation == .update }) else { throw OrchestratedEditError.noChange }
                if primary.relativePath != document.relativePath {
                    self.document = EditableSourceDocument(relativePath: primary.relativePath, content: primary.originalContent)
                    selectedPath = primary.relativePath
                }
                proposedContent = primary.proposedContent
                proposal = primary
                relatedProposals = proposals.filter { $0.relativePath != primary.relativePath }
                orchestratedOutcome = outcome
                presentationMode = .diff
                onGenerationEvent(.proposalReady)
            } catch is CancellationError {
                errorMessage = "AIによる変更案の生成を停止しました。"
                onGenerationEvent(.cancelled)
            } catch {
                errorMessage = error.localizedDescription
                onGenerationEvent(.failed(error.localizedDescription))
            }
            finishGeneration()
        }
    }
}
