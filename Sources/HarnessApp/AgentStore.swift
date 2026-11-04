import ApplicationServices
import Foundation
import HarnessCore
import Observation

/// The agent screen (2026-11-02): requests typed on the Mac or sent from a paired device run Computer Use on this Mac
/// (apps through the accessibility API, Safari, and web search on this Mac's own RustXNG). One request runs at a time;
/// an action that cannot be undone waits for approval from the Mac or the device. The conversation is kept on disk.
@MainActor
@Observable
final class AgentStore {
    static let shared = AgentStore()

    struct Approval: Equatable {
        let id: UUID
        let action: String
        let reason: String
    }

    var entries: [AgentEntry] = []
    var draft = ""
    var pendingApproval: Approval?
    var isRunning = false
    /// When the running request began, for the remaining time here and on the iPhone.
    var startedAt: Date?
    var searchInstalled = LocalWebSearch.isInstalled

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var listeners: [UUID: (AgentEntry) -> Void] = [:]
    @ObservationIgnored let controller = AccessibilityComputerUse()
    @ObservationIgnored let journal = ComputerUseJournal.standard
    @ObservationIgnored let provider: any ModelInferenceProvider =
        LoggingInferenceProvider(base: BackburnerAwareInferenceProvider(base: LocalInferenceService()))
    @ObservationIgnored let model = AgentStore.agentModel

    /// The agent reads a screen or search results every step, so how fast a model reads matters more than how well it
    /// writes (2026-11-04: the 27B read 75-90 tokens a second, 12-18 s a step). Qwen 3.6 35B A3B (3B active) when it is
    /// installed, else the 27B; loaded by itself like every Backburner model.
    static var agentModel: ModelSelection {
        let fast = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf")
        // The projector is fetched after the model, so its presence also says the model file is complete.
        let projector = fast.deletingPathExtension().appendingPathExtension("mmproj.gguf")
        if FileManager.default.fileExists(atPath: fast.path), FileManager.default.fileExists(atPath: projector.path) {
            return ModelSelection(identifier: "gguf:" + fast.path, displayName: "Qwen 3.6 35B A3B", runtime: .backburner)
        }
        return ModelSelection(identifier: "qwen3.8-27b-iq4xs", displayName: "Backburner", runtime: .backburner)
    }
    @ObservationIgnored let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalFactory/Agent/conversation.json")

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([AgentEntry].self, from: data) {
            entries = saved
        }
    }

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Codex's Submission queue: every front end sends its ops here.
    @discardableResult
    func handle(_ op: AgentOp) -> String {
        switch op {
        case .request(let text, let source):
            let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isEmpty else { return "依頼が空です" }
            guard !isRunning else { return "いまは別の依頼を実行中です。終わってから送ってください" }
            start(request, source: source)
            return "受け付けました"
        case .approve(let id, let allowed):
            guard pendingApproval?.id == id else { return "この確認はもう終わっています" }
            answerApproval(allowed)
            return allowed ? "実行します" : "止めました"
        case .interrupt:
            task?.cancel()
            answerApproval(false)
            return "止めました"
        }
    }

    func send() {
        handle(.request(draft, .mac))
        draft = ""
    }

    /// Codex's Event queue: a device listening to the conversation (the remote link) gets every new entry.
    func listen(_ listener: @escaping (AgentEntry) -> Void) -> UUID {
        let id = UUID(); listeners[id] = listener; return id
    }

    func stopListening(_ id: UUID) { listeners[id] = nil }

    func clear() {
        guard !isRunning else { return }
        entries = []
        save()
    }

    private func start(_ request: String, source: AgentSource) {
        let goal = AgentGoal.compose(request: request, entries: entries)
        append(AgentEntry(kind: .request, text: request, detail: goal, source: source))
        isRunning = true
        startedAt = Date()
        let controller = self.controller, journal = self.journal, provider = self.provider, model = self.model
        let search: (@Sendable (String) async throws -> String)? = LocalWebSearch.isInstalled ? { @Sendable query in try await LocalWebSearch().search(query) } : nil
        task = Task { [weak self] in
            weak let store = self
            let result = await ComputerUseAgent.run(
                goal: goal, controller: controller,
                decide: { messages, screenshot in
                    var reply = ""
                    let request = InferenceRequest(runtime: model.runtime, modelIdentifier: model.identifier, messages: messages,
                                                   maximumOutputTokens: 1_200,
                                                   images: await ComputerUseScreenshot.inferenceImages(screenshot), temperature: 0)
                    for try await piece in await provider.events(for: request) { reply += piece }
                    return reply
                },
                approve: { action, reason in
                    let allowed = await store?.askApproval(action: action, reason: reason) ?? false
                    journal.record(goal: goal, approval: (action, reason, allowed))
                    return allowed
                },
                onStep: { step in
                    journal.record(goal: goal, step: step)
                    await store?.append(AgentEntry(kind: .step, text: step.action, detail: step.result))
                },
                search: search)
            journal.record(goal: goal, outcome: "\(result)")
            self?.finish(result)
        }
    }

    private func askApproval(action: String, reason: String) async -> Bool {
        let approval = Approval(id: UUID(), action: action, reason: reason)
        append(AgentEntry(id: approval.id, kind: .approval, text: action, detail: reason))
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            pendingApproval = approval
        }
    }

    private func answerApproval(_ allowed: Bool) {
        pendingApproval = nil
        approvalContinuation?.resume(returning: allowed)
        approvalContinuation = nil
    }

    /// When the running request should be done, going by earlier ones.
    var expectedEnd: Date? {
        guard isRunning, let startedAt, let expected = JobTimeEstimates().expected("agent") else { return nil }
        return startedAt.addingTimeInterval(expected)
    }

    private func finish(_ result: ComputerUseOutcome) {
        isRunning = false
        if case .done = result, let startedAt { JobTimeEstimates().record("agent", seconds: Date().timeIntervalSince(startedAt)) }
        startedAt = nil
        task = nil
        switch result {
        case .done(let summary): append(AgentEntry(kind: .outcome, text: "完了しました: \(summary)"))
        case .needsUser(let message):
            // The question stays in `detail`: the next request is taken as its answer (AgentGoal.compose).
            append(AgentEntry(kind: .outcome, text: "あなたの判断が必要です: \(message)", detail: message))
        case .stopped(let message): append(AgentEntry(kind: .outcome, text: "止めました: \(message)"))
        case .stepLimit:
            append(AgentEntry(kind: .outcome, text: "\(ComputerUseAgent.maximumSteps) 手で終わらなかったので止めました。依頼を細かくして頼み直してください。"))
        }
    }

    private func append(_ entry: AgentEntry) {
        entries.append(entry)
        if entries.count > 400 { entries.removeFirst(entries.count - 400) }
        for listener in listeners.values { listener(entry) }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }
}
