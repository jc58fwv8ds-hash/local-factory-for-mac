import Foundation
import HarnessCore

extension FileChangeSession {
    func askAI() {
        guard canAskAI, let model else { return }
        let instruction = aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let creationPath = newFileRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingDocument = document
        let createsFile = isCreatingNewFile
        if let orchestrator, !createsFile, let existingDocument = document {
            return askOrchestrator(orchestrator, document: existingDocument, instruction: instruction, model: model)
        }
        isGenerating = true
        errorMessage = nil
        proposal = nil
        onGenerationEvent(.started(instruction))

        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let messages: [InferenceMessage]
                if createsFile {
                    try await editor.validateCreationPath(
                        rootPath: rootPath,
                        relativePath: creationPath
                    )
                    let references = await FileCreationReferenceContext.collect(
                        rootPath: rootPath,
                        targetPath: creationPath,
                        files: files,
                        editor: editor
                    )
                    messages = try FileEditPromptBuilder.creationMessages(
                        relativePath: creationPath,
                        instruction: instruction,
                        referenceDocuments: references
                    )
                } else if let existingDocument {
                    messages = try FileEditPromptBuilder.messages(
                        document: existingDocument,
                        instruction: instruction
                    )
                } else {
                    return finishGeneration()
                }
                let request = InferenceRequest(
                    runtime: model.runtime,
                    modelIdentifier: model.identifier,
                    messages: messages,
                    maximumOutputTokens: InferenceOutputBudget.fileChange,
                    structuredOutput: .fileContent
                )
                var response = ""
                let events = await inferenceProvider.events(for: request)
                for try await delta in events {
                    try Task.checkCancellation()
                    response += delta
                }
                try Task.checkCancellation()
                let content = try FileEditResponseParser.proposedContent(from: response)
                let generatedProposal: FileChangeProposal
                if createsFile {
                    generatedProposal = try await editor.makeCreationProposal(
                        rootPath: rootPath,
                        relativePath: creationPath,
                        proposedContent: content
                    )
                } else if let existingDocument {
                    generatedProposal = try await editor.makeProposal(
                        document: existingDocument,
                        proposedContent: content
                    )
                } else {
                    return finishGeneration()
                }
                try Task.checkCancellation()
                proposedContent = content
                proposal = generatedProposal
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

    func stopAI() {
        generationTask?.cancel()
    }

    func finishGeneration() {
        isGenerating = false
        generationTask = nil
    }
}
