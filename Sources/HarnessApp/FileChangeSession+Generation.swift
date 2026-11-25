import Foundation
import HarnessCore

extension FileChangeSession {
    func askAI() {
        guard canAskAI, let model = secondWriter ?? model else { return }
        var instruction = aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        // How the Apple types the step names are really declared, from this Mac's SDK (2026-11-17: SpeechAnalyzer(recognizer:)).
        if let reference = SDKSwiftInterfaceLookup.shared.reference(for: instruction) { instruction += "\n\n" + reference }
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
                } else if let existingDocument, FunctionEdit.applies(to: existingDocument.content) {
                    messages = FunctionEdit.messages(document: existingDocument, instruction: instruction)
                } else if let existingDocument {
                    messages = try FileEditPromptBuilder.messages(
                        document: existingDocument,
                        instruction: instruction
                    )
                } else {
                    return finishGeneration()
                }
                var content: String
                // 2026-11-25: the changed lines only (ReplaceEdit); the whole-file way when they cannot be placed.
                if !createsFile, let existingDocument,
                   let quick = try await replaceEdited(existingDocument, instruction: instruction, model: model) {
                    content = quick
                } else {
                    content = try await writtenContent(
                        messages: messages,
                        model: model,
                        previous: existingDocument?.content
                    )
                    // A long file's answer holds only the functions that change; they go into the file (2026-11-18).
                    if !createsFile, let existingDocument, FunctionEdit.applies(to: existingDocument.content) {
                        content = FunctionEdit.splice(content, into: existingDocument.content) ?? existingDocument.content
                    }
                }
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

    /// The file's new text, asked once more when it still holds a stand-in or a "not supported" stub (2026-11-16: a
    /// language switch that only printed a warning and an empty editor screen were saved and reported as done).
    private func writtenContent(
        messages: [InferenceMessage],
        model: ModelSelection,
        previous: String?
    ) async throws -> String {
        var conversation = messages
        var content = ""
        for attempt in 0..<2 {
            let request = InferenceRequest(
                runtime: model.runtime,
                modelIdentifier: model.identifier,
                messages: conversation,
                maximumOutputTokens: InferenceOutputBudget.fileChange(existingBytes: previous?.utf8.count ?? 0),
                structuredOutput: .fileContent,
                temperature: WriterRetry.temperature(for: conversation)
            )
            var response = ""
            for try await delta in await inferenceProvider.events(for: request) {
                try Task.checkCancellation()
                response += delta
                if DegenerateOutput.isRunaway(response) { throw DegenerateOutput.Failure.runaway }
            }
            try Task.checkCancellation()
            content = try FileEditResponseParser.proposedContent(from: response)
            let unfinished = UnfinishedCode.findings(in: content, previous: previous)
            guard !unfinished.isEmpty, attempt == 0 else { break }
            conversation += [
                InferenceMessage(role: .assistant, content: response),
                InferenceMessage(role: .user, content: UnfinishedCode.feedback(unfinished))
            ]
        }
        return content
    }

    /// The file with the answer's changed lines put in, the file itself when the model says nothing needs changing, or nil
    /// when the answer cannot be placed exactly or leaves a stand-in (the caller then asks for the whole file).
    private func replaceEdited(_ document: EditableSourceDocument, instruction: String, model: ModelSelection) async throws -> String? {
        let request = InferenceRequest(
            runtime: model.runtime,
            modelIdentifier: model.identifier,
            messages: ReplaceEdit.messages(document: document, instruction: instruction),
            maximumOutputTokens: InferenceOutputBudget.fileChange(existingBytes: document.content.utf8.count),
            temperature: 0
        )
        var response = ""
        for try await delta in await inferenceProvider.events(for: request) {
            try Task.checkCancellation()
            response += delta
            if DegenerateOutput.isRunaway(response) { return nil }
        }
        try Task.checkCancellation()
        switch ReplaceEdit.apply(response, to: document.content) {
        case let .changed(text):
            return UnfinishedCode.findings(in: text, previous: document.content).isEmpty ? text : nil
        case .unchanged:
            return document.content
        case .failed:
            return nil
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
