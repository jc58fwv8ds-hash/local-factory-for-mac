import Foundation
import HarnessCore

/// One image asked for in the chat (2026-10-09): the instruction becomes an English prompt (the "large" role model), the
/// language models leave memory, and the image model chosen for 画像を作る runs. The picture is saved on this Mac.
@MainActor
@Observable
final class ImageChange: Identifiable {
    enum Status: Equatable { case running(String), ready(URL), failed(String) }
    let id: UUID
    let instruction: String
    var status: Status = .running("指示を画像用の言葉にしています")
    var prompt: String?

    init(id: UUID, instruction: String) {
        self.id = id
        self.instruction = instruction
    }
}

/// A request that needs the user's yes first (a sexual remake of an attached photo): the text waits here.
struct PendingConsent: Equatable {
    let instruction: String
    let reason: String
}

extension WorkspaceStore {
    var purposeSettings: PurposeModelSettings { purposeSettingsOverride ?? PurposeModelSettings() }

    static var imageFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harness/Images", isDirectory: true)
    }

    /// Writing and image messages: the two lines first (ContentGuard), then the purpose's own model. Returns false when the
    /// message is not for one of these purposes.
    func submitPurposeInstruction() -> Bool {
        guard composerPurpose != .conversation else { return false }
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        switch ContentGuard.check(text, attachesPhoto: composerPurpose == .image && !visualAttachments.items.isEmpty) {
        case .block(let reason):
            presentNotice(reason, kind: .information)
            return true
        case .confirmConsent(let reason):
            pendingConsent = PendingConsent(instruction: text, reason: reason)
            return true
        case .allow:
            break
        }
        continuePurposeInstruction(text)
        return true
    }

    /// After 「同意を得ている」 on the consent question, or directly when nothing needs asking.
    func continuePurposeInstruction(_ text: String) {
        pendingConsent = nil
        switch composerPurpose {
        case .writing:
            let decision = acceptInstruction(text, origin: .user, images: visualAttachments.inferenceImages,
                                             documents: documentAttachments,
                                             modelOverride: purposeSettings.chosen(.writing)?.selection)
            if decision.status == .accepted || decision.status == .queued {
                instruction = ""
                documentAttachments = []
                visualAttachments.clear()
            } else {
                presentNotice(decision.message, kind: .information)
            }
        case .image:
            startImage(text)
            instruction = ""
            visualAttachments.clear()
        case .conversation:
            break
        }
    }

    func startImage(_ text: String) {
        let message = ConversationMessage(role: .user, content: text, origin: .user)
        library.updateSelectedProject { $0.conversation.append(message) }
        persist()
        let change = ImageChange(id: message.id, instruction: text)
        imageChanges[message.id] = change
        Task { await runImage(change) }
    }

    func runImage(_ change: ImageChange) async {
        let settings = purposeSettings
        guard let option = settings.chosen(.image) else {
            change.status = .failed("画像を作るモデルが選ばれていません。「AIモデル」の「用途ごとのモデル」で選んでください。")
            return
        }
        // The prompt writer follows the writing choice's roles (the "large" role), else the project's model.
        let writer = settings.chosen(.writing).flatMap { settings.catalog.roleModel("large", chosen: $0) } ?? project.selectedModel
        var prompt = change.instruction
        if let writer {
            let request = InferenceRequest(runtime: writer.runtime, modelIdentifier: writer.identifier, messages: [
                InferenceMessage(role: .user, content: """
                Rewrite this request as one English prompt for an image model. Keep every detail the user gave (subject, \
                style, composition, colors, mood); add nothing they did not ask for. Output only the prompt.
                \(change.instruction)
                """)], maximumOutputTokens: 300, temperature: 0)
            var english = ""
            do {
                for try await piece in await inferenceProvider.events(for: request) { english += piece }
            } catch { english = "" }
            let cleaned = english.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, !ModelRefusal.looksLikeRefusal(cleaned) { prompt = cleaned }
        }
        change.prompt = prompt
        change.status = .running("画像を作っています(言語モデルをメモリから外しました。数分かかります)")
        let output = Self.imageFolder.appendingPathComponent("\(change.id.uuidString.prefix(8))-\(option.id).png")
        do {
            try await imageGenerator.generate(option: option, prompt: prompt, output: output)
            change.status = .ready(output)
            appendAssistantNote("画像ができました(\(option.label))。保存先: \(output.path)")
        } catch {
            change.status = .failed(error.localizedDescription)
        }
    }
}
