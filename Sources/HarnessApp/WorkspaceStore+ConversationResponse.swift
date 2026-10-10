import Foundation
import HarnessCore

extension WorkspaceStore {
    /// Transient quality checking belongs to one accepted instruction and one checkpoint.
    func generateConversationResponse(
        for project: HarnessProject,
        model: ModelSelection,
        sourceContext: SourceContextSnapshot?,
        images: [InferenceImage] = [],
        documents: [DocumentText] = [],
        deliveryMode: ConversationDeliveryMode = .screen
    ) async throws {
        let request = InferenceRequest(
            runtime: model.runtime,
            modelIdentifier: model.identifier,
            messages: ProjectPromptBuilder.messages(
                for: project,
                sourceContext: sourceContext,
                visualAttachments: images.map(\.descriptor),
                visualTextTranscripts: images.compactMap(\.recognizedText),
                documentTexts: documents,
                deliveryMode: deliveryMode,
                voiceProfile: deliveryMode == .voice
                    ? voiceLibrary.selectedProfile
                    : nil
            ),
            maximumOutputTokens: InferenceOutputBudget.conversation,
            images: images
        )
        let continuation = ContinuationResponsePolicy(project: project)
        let rephrase = ConversationRephrasePolicy(project: project)
        let sentenceCount = ConversationSentenceCountPolicy(project: project)
        generationPhase = .generating
        try await streamConversationResponse(request)
        let revisionRequest: InferenceRequest?
        if continuation?.repeats(streamingResponse) == true {
            revisionRequest = continuation?.refinementRequest(from: request)
        } else if rephrase?.repeats(streamingResponse) == true {
            revisionRequest = rephrase?.refinementRequest(
                from: request, response: streamingResponse
            )
        } else if sentenceCount?.validationError(for: streamingResponse) != nil {
            revisionRequest = sentenceCount?.refinementRequest(
                from: request, response: streamingResponse
            )
        } else {
            revisionRequest = nil
        }
        guard let revisionRequest else { return }

        generationPhase = .revisingResponse
        streamingResponse = ""
        try await streamConversationResponse(revisionRequest)
        if continuation?.repeats(streamingResponse) == true {
            throw InferenceError.repeatedResponse
        }
        if rephrase?.repeats(streamingResponse) == true {
            throw InferenceError.unchangedRephrase
        }
        if let error = sentenceCount?.validationError(for: streamingResponse) {
            throw error
        }
    }

    private func streamConversationResponse(_ request: InferenceRequest) async throws {
        try Task.checkCancellation()
        var timer = InferenceResponseTimer(request: request)
        let events = await inferenceProvider.events(for: request)
        var rawResponse = ""
        for try await delta in events {
            try Task.checkCancellation()
            rawResponse += delta
            streamingResponse = ConversationResponseText.visibleText(rawResponse, isComplete: false)
            timer.observe(hasVisibleContent: !streamingResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        // A cancelled stream may finish normally; EOF is not proof of completion.
        try Task.checkCancellation()
        streamingResponse = ConversationResponseText.visibleText(rawResponse)
        timer.observe(hasVisibleContent: !streamingResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        generationTimings.append(timer.measurement())
    }
}
