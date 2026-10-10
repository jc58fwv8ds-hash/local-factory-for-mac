import Foundation
import HarnessCore

extension WorkspaceStore {
    func submitInstruction() {
        if voiceConversation.isActive {
            voiceConversation.stop()
        }
        guard !visualAttachments.isImporting else {
            presentNotice("画像の読み込みが終わるまで少し待ってね", kind: .information)
            return
        }
        // 文章を書く / 画像を作る: the user's own choice of purpose; no code-change routing and no system-model check.
        if submitPurposeInstruction() { return }
        if PrimaryInstructionIntentRouter.route(instruction) == .computerOperation {
            if handoffPrimaryInstructionToComputerOperator(instruction) {
                instruction = ""
            }
            return
        }
        // A change request with an Excel file attached: cell edits previewed on a copy, written to a new file on apply.
        if documentAttachments.contains(where: { $0.kind == "Excel" }), submitSpreadsheetEdit(instruction) {
            instruction = ""
            documentAttachments = []
            return
        }
        // A Word edit with a .docx attached: text replaced in a scratch copy, written to a new file on apply.
        if documentAttachments.contains(where: { $0.kind == "Word" }), submitWordEdit(instruction) {
            instruction = ""
            documentAttachments = []
            return
        }
        // A PDF edit with PDFs attached: operations previewed in memory, written to a new file on apply.
        if documentAttachments.contains(where: { $0.kind == "PDF" }), submitPDFEdit(instruction) {
            instruction = ""
            documentAttachments = []
            return
        }
        // A question about attached tables: SQL by the model, numbers by DuckDB.
        if documentAttachments.contains(where: { ["Excel", "表(CSV)"].contains($0.kind) }), submitAnalysis(instruction) {
            instruction = ""
            documentAttachments = []
            return
        }
        // A rename request with a folder attached: the model writes a rule, the card shows every new name before renaming.
        if attachedFolder != nil, BulkRenameIntent.isRenameRequest(instruction), submitRenameRequest(instruction) {
            instruction = ""
            return
        }
        // A change request on a connected Swift package runs the verified harness and comes back as a card in the chat.
        if PrimaryInstructionIntentRouter.isCodeChangeRequest(instruction), chatCodeChangeContext != nil,
           submitChatCodeChange(instructionWithDocuments(instruction), images: visualAttachments.inferenceImages) {
            instruction = ""
            visualAttachments.clear()
            documentAttachments = []
            return
        }
        // Request-like messages without a keyword: the on-device system model decides (Neural Engine, ~1-4 s). If it is
        // unavailable or unsure, the message stays conversation.
        if chatCodeChangeContext != nil, PrimaryInstructionIntentRouter.mayBeChangeRequest(instruction) {
            let text = instruction
            let images = visualAttachments.inferenceImages
            instruction = ""
            Task { @MainActor in
                if await SystemIntentClassifier.isCodeChange(text) == true,
                   submitChatCodeChange(instructionWithDocuments(text), images: images) {
                    visualAttachments.clear()
                    documentAttachments = []
                    return
                }
                instruction = text
                submitConversationInstruction()
            }
            return
        }
        submitConversationInstruction()
    }

    private func submitConversationInstruction() {
        let decision = acceptInstruction(
            instruction,
            origin: .user,
            images: visualAttachments.inferenceImages,
            documents: documentAttachments
        )
        if decision.status == .accepted || decision.status == .queued {
            instruction = ""
            documentAttachments = []
        } else {
            presentNotice(decision.message, kind: .information)
        }
    }

    func acceptRemoteInstruction(_ instruction: String) -> RemoteInstructionDecision {
        acceptInstruction(instruction, origin: .remoteUser, images: [])
    }

    func acceptInstruction(
        _ submittedInstruction: String,
        origin: ConversationOrigin,
        images: [InferenceImage],
        documents: [DocumentText] = [],
        modelOverride: ModelSelection? = nil,
        deliveryMode: ConversationDeliveryMode = .screen
    ) -> RemoteInstructionDecision {
        var cleaned = submittedInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return RemoteInstructionDecision(status: .rejected, message: "空の指示は受け付けません")
        }
        let interaction = deliveryMode == .voice
            ? WorkspaceInteractionOperation.submitVoiceTurn
            : .submitInstruction
        if let blocker = interactionBlocker(for: interaction) {
            return RemoteInstructionDecision(
                status: .busy,
                message: interactionMessage(for: blocker)
            )
        }
        guard let record = library.selectedRecord else {
            return RemoteInstructionDecision(
                status: .unavailable,
                message: "Local Factoryでプロジェクトを選択してください"
            )
        }
        if !images.isEmpty {
            guard let model = record.project.selectedModel else {
                return RemoteInstructionDecision(
                    status: .unavailable,
                    message: "画像を見るAIモデルを先に選んでください"
                )
            }
            let capabilities = VisualModelCapabilityResolver.capabilities(for: model)
            let routing = VisualModelRoutingPolicy.decision(
                for: .understandReference,
                capabilities: capabilities
            )
            guard routing.route == .visionModel else {
                return RemoteInstructionDecision(
                    status: .unavailable,
                    message: routing.userMessage
                )
            }
        }

        // The conversation keeps only the names; the text goes to the model for this turn (DocumentPromptBuilder).
        if !documents.isEmpty { cleaned += "\n(添付: " + documents.map(\.displayName).joined(separator: "、") + ")" }
        var workItemID = UUID()
        library.updateSelectedProject { project in
            workItemID = ProjectInferenceWorkflow.accept(
                instruction: cleaned,
                workItemID: workItemID,
                origin: origin,
                visualAttachments: images.map(\.descriptor),
                in: &project
            )
        }
        persist(successMessage: origin == .remoteUser
            ? "iPhoneからの指示を受け付けました"
            : "指示を受け付けました")

        guard let selectedModel = modelOverride ?? record.project.selectedModel else {
            presentNotice("実行するにはAIモデルを選択してください", kind: .information)
            return RemoteInstructionDecision(
                status: .queued,
                message: "「\(record.project.name)」へ保存しました。AIモデルの選択後に実行できます"
            )
        }
        beginGeneration(
            projectID: record.id,
            workItemID: workItemID,
            model: selectedModel,
            sourcePath: record.sourceLocation,
            images: images,
            documents: documents,
            deliveryMode: deliveryMode
        )
        return RemoteInstructionDecision(
            status: .accepted,
            message: "「\(record.project.name)」でAIが指示を確認しています"
        )
    }

    /// A code change made while documents are attached gets their text, like the text read from attached images.
    func instructionWithDocuments(_ text: String) -> String {
        guard !documentAttachments.isEmpty else { return text }
        return text + "\n\n" + documentAttachments.map { "【添付文書「\($0.displayName)」(\($0.kind))】\n" + String($0.text.prefix(12_000)) }
            .joined(separator: "\n\n")
    }

    func attachDocuments(_ urls: [URL]) {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                var document = try DocumentReader.read(url)
                document.sourcePath = url.path
                documentAttachments.append(document)
            } catch {
                presentNotice(error.localizedDescription, kind: .information)
            }
        }
    }

    func removeDocument(_ id: UUID) {
        documentAttachments.removeAll { $0.id == id }
    }
}
