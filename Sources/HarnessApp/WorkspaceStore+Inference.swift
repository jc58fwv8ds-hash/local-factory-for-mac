import Foundation
import HarnessCore

extension WorkspaceStore {
    var interruptedInferenceCheckpoint: ProjectOperationCheckpoint? {
        guard !isGeneratingSelectedProject,
              project.operationCheckpoint?.operation == .modelInference else {
            return nil
        }
        return project.operationCheckpoint
    }

    var canResumeInterruptedInference: Bool {
        guard !isGenerating,
              project.selectedModel != nil,
              let workItemID = interruptedInferenceCheckpoint?.referenceID else {
            return false
        }
        return project.workItems.contains { $0.id == workItemID }
    }

    func stopGeneration() {
        inferenceTask?.cancel()
    }

    func resumeInterruptedInference() {
        guard !isGenerating,
              let record = library.selectedRecord,
              let model = record.project.selectedModel,
              let workItemID = record.project.operationCheckpoint?.referenceID,
              record.project.operationCheckpoint?.operation == .modelInference else {
            presentNotice("再実行するAIモデルまたは保存済みの指示を確認できません", kind: .information)
            return
        }
        let requiredImages = visualDescriptors(
            for: workItemID,
            in: record.project
        )
        if !requiredImages.isEmpty {
            let availableHashes = Set(visualAttachments.descriptors.map(\.contentHash))
            guard requiredImages.allSatisfy({ availableHashes.contains($0.contentHash) }) else {
                presentNotice(
                    "この指示には画像がありました。安全のため、同じ画像をもう一度追加してから再開してね。",
                    kind: .information
                )
                return
            }
        }
        var didResume = false
        library.updateProject(record.id) { project in
            didResume = ProjectInferenceWorkflow.resume(
                workItemID: workItemID,
                model: model,
                in: &project
            )
        }
        guard didResume else {
            presentNotice("再実行する制作項目を確認できません", kind: .information)
            return
        }
        persist(successMessage: "保存済みの指示からAI応答を再実行します")
        beginGeneration(
            projectID: record.id,
            workItemID: workItemID,
            model: model,
            sourcePath: record.sourceLocation,
            images: visualAttachments.inferenceImages
        )
    }

    func discardInterruptedInference() {
        guard let record = library.selectedRecord,
              record.project.operationCheckpoint?.operation == .modelInference else {
            return
        }
        let workItemID = record.project.operationCheckpoint?.referenceID
        library.updateProject(record.id) { project in
            if let workItemID {
                ProjectInferenceWorkflow.cancel(
                    workItemID: workItemID,
                    in: &project
                )
            }
            ProjectOperationCheckpointWorkflow.discarded(in: &project)
        }
        persist(successMessage: "中断したAI応答の記録を破棄しました")
    }

    func beginGeneration(
        projectID: UUID,
        workItemID: UUID,
        model: ModelSelection,
        sourcePath: String?,
        images: [InferenceImage] = [],
        documents: [DocumentText] = [],
        deliveryMode: ConversationDeliveryMode = .screen
    ) {
        generationTimings = []
        lastConversationPerformance = nil
        library.updateProject(projectID) { project in
            ProjectOperationCheckpointWorkflow.started(
                .modelInference,
                referenceID: workItemID,
                in: &project
            )
        }
        persist()
        generationPhase = sourcePath == nil ? .generating : .preparingSource
        streamingResponse = ""
        generationProjectID = projectID

        inferenceTask = Task { [weak self] in
            guard let self else { return }

            do {
                let sourceContext = try await prepareSourceContext(
                    path: sourcePath,
                    projectID: projectID,
                    model: model
                )
                try Task.checkCancellation()

                guard let projectSnapshot = library.records.first(
                    where: { $0.id == projectID }
                )?.project else {
                    throw CancellationError()
                }

                try await generateConversationResponse(
                    for: projectSnapshot,
                    model: model,
                    sourceContext: sourceContext,
                    images: images,
                    documents: documents,
                    deliveryMode: deliveryMode
                )
                try Task.checkCancellation()
                completeGeneration(
                    projectID: projectID,
                    workItemID: workItemID,
                    model: model
                )
            } catch is CancellationError {
                cancelGeneration(projectID: projectID, workItemID: workItemID)
            } catch {
                failGeneration(
                    error,
                    projectID: projectID,
                    workItemID: workItemID,
                    model: model
                )
            }
        }
    }

    private func prepareSourceContext(
        path: String?,
        projectID: UUID,
        model: ModelSelection
    ) async throws -> SourceContextSnapshot? {
        guard let path else { return nil }

        do {
            let snapshot = try await sourceContextProvider.collect(
                path: path,
                budget: SourceContextBudgetPolicy.budget(for: model)
            )
            let selection = library.records.first(where: { $0.id == projectID }).map {
                SourceContextSelectionPolicy.select(snapshot, for: $0.project)
            } ?? SourceContextSelection(
                snapshot: snapshot,
                strategy: .allAvailable,
                originalFileCount: snapshot.files.count,
                originalCharacterCount: snapshot.totalCharacters
            )
            library.updateProject(projectID) { project in
                ProjectInferenceWorkflow.preparedSourceContext(selection, in: &project)
            }
            persist()
            return selection.snapshot
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            library.updateProject(projectID) { project in
                ProjectInferenceWorkflow.sourceContextUnavailable(
                    message: error.localizedDescription,
                    in: &project
                )
            }
            persist()
            return nil
        }
    }

    private func completeGeneration(
        projectID: UUID,
        workItemID: UUID,
        model: ModelSelection
    ) {
        let response = streamingResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty else {
            failGeneration(
                InferenceError.emptyResponse,
                projectID: projectID,
                workItemID: workItemID,
                model: model
            )
            return
        }

        library.updateProject(projectID) { project in
            ProjectInferenceWorkflow.complete(
                response: response,
                model: model,
                workItemID: workItemID,
                in: &project
            )
            ProjectOperationCheckpointWorkflow.completed(
                .modelInference,
                in: &project
            )
        }
        if let response = library.records.first(where: { $0.id == projectID })?.project.conversation.last,
           response.origin == .localModel, !generationTimings.isEmpty {
            lastConversationPerformance = ConversationPerformance(
                projectID: projectID, responseID: response.id, attempts: generationTimings
            )
        }
        persist(successMessage: "AIモデルから応答を受け取りました")
        resetGenerationState()
        voiceConversation.handleResponse(response, projectID: projectID)
        if !visualAttachments.items.isEmpty {
            visualAttachments.clear()
        }
    }

    private func cancelGeneration(projectID: UUID, workItemID: UUID) {
        library.updateProject(projectID) { project in
            ProjectInferenceWorkflow.cancel(workItemID: workItemID, in: &project)
        }
        persist(successMessage: "AIの生成を停止しました")
        resetGenerationState()
        voiceConversation.handleGenerationEnded(
            projectID: projectID,
            message: "AIの生成を停止しました。続けて話せます"
        )
    }

    private func failGeneration(
        _ error: Error,
        projectID: UUID,
        workItemID: UUID,
        model: ModelSelection
    ) {
        library.updateProject(projectID) { project in
            ProjectInferenceWorkflow.fail(
                message: error.localizedDescription,
                model: model,
                workItemID: workItemID,
                in: &project
            )
            ProjectOperationCheckpointWorkflow.completed(
                .modelInference,
                in: &project
            )
        }
        persist()
        presentNotice(error.localizedDescription, kind: .error)
        resetGenerationState()
        voiceConversation.handleGenerationEnded(
            projectID: projectID,
            message: "返答を作れませんでした。画面の案内を確認して、続けて話してね"
        )
    }

    private func resetGenerationState() {
        generationPhase = .idle
        streamingResponse = ""
        generationProjectID = nil
        generationTimings = []
        inferenceTask = nil
    }

    private func visualDescriptors(
        for workItemID: UUID,
        in project: HarnessProject
    ) -> [VisualAttachmentDescriptor] {
        guard let messageID = project.workItems.first(where: { $0.id == workItemID })?
            .responseToMessageID else { return [] }
        return project.conversation.first(where: { $0.id == messageID })?
            .visualAttachments ?? []
    }
}
