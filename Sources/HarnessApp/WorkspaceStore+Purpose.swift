import Foundation
import HarnessCore

/// One image asked for in the chat (2026-10-09): the instruction becomes an English prompt (the "large" role model), the
/// language models leave memory, and the image model chosen for 画像を作る runs. The picture is saved on this Mac.
@MainActor
@Observable
final class ImageChange: Identifiable {
    enum Status: Equatable { case running(String), ready(URL), failed(String), stopped }
    /// Image and video jobs run one at a time, in the order asked (2026-11-04: a second request beside a running one looked
    /// stuck on 「言葉にしています」 because its writer was waiting for the model memory).
    static var lastInQueue: Task<Void, Never>?
    var task: Task<Void, Never>?
    var isRunning: Bool { if case .running = status { true } else { false } }
    let id: UUID
    let instruction: String
    var status: Status = .running("準備しています")
    /// For the remaining time: what the time is filed under once the model is known, and when the job began.
    var jobKind: String?
    var startedAt = Date()
    var prompt: String?
    /// A video's character: the attached picture (a generated image attached again), which becomes its first frame.
    var referenceImage: Data?
    /// A picture attached to an image request: its person is described to the prompt writer (2026-11-07: an attached person
    /// was ignored and the prompt said only "a person").
    var personPicture: Data?
    /// The seed it was made with; a follow-up that changes this output uses it again.
    var seed = Int.random(in: 1...999_999)
    /// A video request (2026-10-19): the same flow with the 動画を作る model, saved as .mp4.
    let isVideo: Bool
    var purpose: ModelPurpose { isVideo ? .video : .image }

    init(id: UUID, instruction: String, isVideo: Bool = false) {
        self.id = id
        self.instruction = instruction
        self.isVideo = isVideo
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
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        // Asked in words while the menu says 会話: it goes where it can really be made, for this message only.
        var routed = false
        if workspaceMode == .chat, composerPurpose == .conversation, documentAttachments.isEmpty, let kind = GeneratedMedia.requestedKind(text) {
            composerPurpose = kind == .video ? .video : .image
            routed = true
        }
        guard workspaceMode == .chat, composerPurpose != .conversation else { return false }
        guard !text.isEmpty else { return true }
        // The last few instructions count too: an edit carries the earlier subject along (「小学生の写真」, then 「裸にして」).
        let recent = ProjectInstructionContext.userMessages(in: project).suffix(6).map(\.content) + [text]
        switch ContentGuardSettings().check(recent.joined(separator: "\n"), attachesPhoto: composerPurpose != .writing && !visualAttachments.items.isEmpty) {
        case .block(let reason):
            presentNotice(reason, kind: .information)
            if routed { composerPurpose = .conversation }
            return true
        case .confirmConsent(let reason):
            pendingConsent = PendingConsent(instruction: text, reason: reason)
            return true
        case .allow:
            break
        }
        continuePurposeInstruction(text)
        if routed { composerPurpose = .conversation }
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
        case .video:
            startVideo(text)
            instruction = ""
            visualAttachments.clear()
        case .conversation:
            break
        }
    }

    /// What a file was made from, beside it: a change asked for after the app restarted still builds on it.
    nonisolated static func saveRecipe(prompt: String, seed: Int, for output: URL) {
        guard FileManager.default.fileExists(atPath: output.path) else { return }
        let data = try? JSONSerialization.data(withJSONObject: ["prompt": prompt, "seed": seed])
        try? data?.write(to: output.appendingPathExtension("json"))
    }

    nonisolated static func savedRecipe(for output: URL) -> (prompt: String, seed: Int)? {
        guard let data = try? Data(contentsOf: output.appendingPathExtension("json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let prompt = json["prompt"] as? String, let seed = json["seed"] as? Int else { return nil }
        return (prompt, seed)
    }

    func startVideo(_ text: String) { startImage(text, isVideo: true) }

    func startImage(_ text: String, isVideo: Bool = false) {
        let message = ConversationMessage(role: .user, content: text, origin: .user)
        library.updateSelectedProject { $0.conversation.append(message) }
        persist()
        let change = ImageChange(id: message.id, instruction: text, isVideo: isVideo)
        if !isVideo { change.personPicture = visualAttachments.items.first?.data }
        if isVideo {
            change.referenceImage = visualAttachments.items.first?.data
            if change.referenceImage == nil, GeneratedMedia.pointsAtLastImage(text),
               let last = GeneratedMedia.lastFile(.image, in: project.conversation.map(\.content)) {
                change.referenceImage = try? Data(contentsOf: last)
            }
        }
        if imageChanges.values.contains(where: \.isRunning) { change.status = .running("順番待ち") }
        imageChanges[message.id] = change
        let before = ImageChange.lastInQueue
        change.task = Task {
            await before?.value
            guard !Task.isCancelled else { return }
            await runImage(change)
        }
        ImageChange.lastInQueue = change.task
    }

    /// The card's 止める: a job not begun never starts; a running one has its program stopped.
    func stopImage(_ change: ImageChange) {
        guard change.isRunning else { return }
        change.task?.cancel()
        change.status = .stopped
    }

    func runImage(_ change: ImageChange) async {
        change.startedAt = Date()
        change.status = .running("準備しています")
        let settings = purposeSettings
        let noun = change.isVideo ? "動画" : "画像"
        // A length or a character needs a model that takes them; the chosen one if it does, else the first that does.
        let wanted = change.isVideo ? VideoLength.seconds(in: change.instruction) : nil
        let chosen = settings.chosen(change.purpose)
        let takesExtras = { (option: PurposeModelOption) in option.command?.contains("{seconds}") == true }
        let needsExtras = change.referenceImage != nil || wanted != nil || (change.isVideo && UserDefaults.standard.object(forKey: VideoLength.settingKey) != nil)
        let capable = needsExtras && chosen.map(takesExtras) != true ? settings.catalog.options(for: .video).first(where: takesExtras) : nil
        let selected = capable ?? chosen
        let seconds = selected.map(takesExtras) == true ? wanted ?? (UserDefaults.standard.object(forKey: VideoLength.settingKey) as? Int) ?? VideoLength.defaultSeconds : nil
        change.jobKind = selected.map { "image:" + $0.id + (seconds.map { "@\($0)s" } ?? "") }
        guard let option = selected else {
            change.status = .failed("\(noun)を作るモデルが選ばれていません。「AIモデル」の「用途ごとのモデル」で選んでください。")
            return
        }
        // The prompt writer follows the writing choice's roles (the "large" role), else the project's model.
        // The chat's own model when one is chosen: it is usually already in memory, and swapping to another 27B costs 3 s (2026-11-05).
        // The prompt writer of the catalog's roles (2026-11-07: a 9B model that also sees pictures, 22 tokens/s),
        // else the chat's own model.
        let writer = settings.catalog.roles?["promptWriter"].flatMap { settings.catalog.option(id: $0, for: .writing)?.selection }
            ?? settings.chosen(.conversation)?.selection ?? settings.chosen(.writing).flatMap { settings.catalog.roleModel("large", chosen: $0) } ?? (project.selectedModel ?? WorkspaceStore.automaticModel)
        // The last output of the same kind in this conversation: a new instruction may be a change to it.
        let ids = Set(project.conversation.map(\.id))
        let previous: (prompt: String?, seed: Int)? = change.referenceImage != nil || change.personPicture != nil ? nil : imageChanges.values
            .filter { $0.id != change.id && $0.isVideo == change.isVideo && ids.contains($0.id) && $0.prompt != nil }
            .filter { if case .ready = $0.status { true } else { false } }
            .max { $0.startedAt < $1.startedAt }
            .map { ($0.prompt, $0.seed) }
            ?? GeneratedMedia.lastFile(change.isVideo ? .video : .image, in: project.conversation.map(\.content))
                .flatMap(Self.savedRecipe).map { ($0.prompt, $0.seed) }
        var prompt = previous?.prompt.map { OutputFollowUp.fallback(instruction: change.instruction, previousPrompt: $0) } ?? change.instruction
        if let previous { change.seed = previous.seed }
        // A writer that refuses is replaced once by the refusal model (2026-11-02);
        // if that refuses too, the user's own words go to the model.
        let fallback = ContentGuardSettings().refusalFallback(catalog: settings.catalog)
        let earlier = OutputFollowUp.earlierConversation(project.conversation, before: change.id)
        // The person from before, shown to the writer so the new prompt describes the same person (2026-11-07: a follow-up
        // drew someone else). The video's own picture, else the last picture when the request points at it or changes it.
        let lastPicture = GeneratedMedia.lastFile(.image, in: project.conversation.map(\.content))
        let personData = change.referenceImage ?? change.personPicture
            ?? ((previous != nil && !change.isVideo) || GeneratedMedia.pointsAtLastImage(change.instruction) ? lastPicture.flatMap { try? Data(contentsOf: $0) } : nil)
        let personImages = await ComputerUseScreenshot.inferenceImages(personData)
        // Only the person's looks come from the picture: its pose must not replace what was asked (2026-11-07: 「自慰をさせて」
        // became "hands resting near her chest", the pose the picture had).
        let keepPerson = personImages.isEmpty ? "" : "The attached picture shows the person from before. Keep the same person: describe only their looks (face, age, ethnicity, hair, skin, body). Do not describe the pose or action in the picture; the action is the one the user asks for above, and it must be the main, clearly stated content of the prompt. "
        for model in [writer, fallback].compactMap({ $0 }).reduce(into: [ModelSelection](), { if !$0.contains($1) { $0.append($1) } }) {
            let request = InferenceRequest(runtime: model.runtime, modelIdentifier: model.identifier, messages: [
                InferenceMessage(role: .user, content: earlier + (change.isVideo && previous == nil ? OutputFollowUp.videoRequest(instruction: change.instruction, hasPicture: !personImages.isEmpty) : previous?.prompt.map { OutputFollowUp.request(instruction: change.instruction, previousPrompt: $0, kind: noun == "動画" ? "video" : "image") } ?? """
                Rewrite this request as one English prompt for \(change.isVideo ? "a video model. Start with the action the user asks for, and describe it as continuous motion that keeps going through the whole clip; give the camera movement in plain camera terms (for example 「舐めるような」 means a slow, close camera gliding along the body, 「俯瞰」 means from above). End with \"Audio: \" and the sounds of the scene, which the model makes with the picture" : "an image model"). State the requested action plainly and first; never soften, leave out or replace it. Name bodies and acts with plain, direct words, and describe what the hands and body physically do, where and in what rhythm (for example "her hand moves back and forth between her legs in a steady rhythm"); no euphemisms. Never translate a figurative word literally. Keep every detail the user gave (subject, \
                style, composition, colors, mood); add nothing they did not ask for. \(change.referenceImage == nil ? "" : "A picture of the character is the first frame: describe what the character does and how the scene moves, keeping the character as in the picture. ")Output only the prompt.
                \(change.instruction)
                """) + (keepPerson.isEmpty || (change.isVideo && previous == nil) ? "" : "\n\n" + keepPerson))], maximumOutputTokens: 400, images: personImages, temperature: 0)
            guard !Task.isCancelled else { return }
            var english = ""
            do {
                for try await piece in await inferenceProvider.events(for: request) { english += piece }
            } catch { english = "" }
            let cleaned = english.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, !ModelRefusal.looksLikeRefusal(cleaned) {
                if previous == nil { prompt = cleaned; break }
                let answer = OutputFollowUp.parse(cleaned)
                guard !answer.prompt.isEmpty else { continue }
                prompt = answer.prompt
                if !answer.isEdit { change.seed = Int.random(in: 1...999_999) }
                break
            }
        }
        guard !Task.isCancelled else { return }
        // Motion sentences are for videos only: in a picture prompt they made stiff, broken bodies (2026-11-07).
        let hints = change.isVideo ? settings.catalog.motionHints(for: change.instruction).filter { !prompt.contains($0) } : []
        if !hints.isEmpty { prompt += " " + hints.joined(separator: " ") }
        change.prompt = prompt
        change.status = .running("\(noun)を作っています" + (seconds.map { "(\($0) 秒" + (change.referenceImage == nil ? "" : "、添付の画像から") + ")" } ?? "") + "")
        var reference: URL?
        // A picture model that keeps a person (its command takes {image}) gets the attached or last picture too (2026-11-07).
        if let data = change.referenceImage ?? (option.command?.contains("{image}") == true ? personData : nil) {
            let file = Self.imageFolder.appendingPathComponent("\(change.id.uuidString.prefix(8))-reference.png")
            try? FileManager.default.createDirectory(at: Self.imageFolder, withIntermediateDirectories: true)
            if (try? data.write(to: file)) != nil { reference = file }
        }
        let output = Self.imageFolder.appendingPathComponent(
            "\(change.id.uuidString.prefix(8))-\(option.id).\(change.isVideo ? "mp4" : "png")")
        InferenceIndicator.shared.begin(.media)
        defer { InferenceIndicator.shared.finish() }
        // The copy of the attached picture is only for this run; a stopped run leaves no half-made output behind.
        defer {
            if let reference { try? FileManager.default.removeItem(at: reference) }
            if Task.isCancelled { try? FileManager.default.removeItem(at: output) }
        }
        do {
            try await imageGenerator.generate(option: option, prompt: prompt, output: output, options: ImageGenerationOptions(seed: change.seed, seconds: seconds, image: reference))
            guard !Task.isCancelled else { return }
            Self.saveRecipe(prompt: prompt, seed: change.seed, for: output)
            change.status = .ready(output)
            if let kind = change.jobKind { JobTimeEstimates().record(kind, seconds: Date().timeIntervalSince(change.startedAt)) }
            appendAssistantNote("\(noun)ができました(\(option.label))。保存先: \(output.path)")
        } catch {
            guard !Task.isCancelled else { return }
            change.status = .failed(error.localizedDescription)
        }
    }
}
