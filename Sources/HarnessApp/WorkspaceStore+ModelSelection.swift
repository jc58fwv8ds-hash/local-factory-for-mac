import Foundation
import HarnessCore

extension WorkspaceStore {
    /// What a chat answer's time is filed under: each model has its own speed.
    var generationJobKind: String { "chat:" + (effectiveModel?.identifier ?? "") }

    /// The start of an answer, and its length once it ends (for the remaining time beside the input field).
    func generationTimingChanged(from old: GenerationPhase) {
        if old == .idle, generationPhase != .idle { generationStartedAt = Date() }
        if old != .idle, generationPhase == .idle, let start = generationStartedAt {
            JobTimeEstimates().record(generationJobKind, seconds: Date().timeIntervalSince(start))
            generationStartedAt = nil
        }
    }

    /// True when a request has a model to go to: the one picked for this project, or the 27B the App loads by itself
    /// (2026-11-04, the user: 「AI 未接続」 showed while everything worked; nobody should have to pick a model first).
    var hasConfiguredModel: Bool { effectiveModel != nil }

    var effectiveModel: ModelSelection? { project.selectedModel ?? Self.automaticModel }

    /// Backburner's 27B when it is installed: started on first use and stopped when another model needs the memory.
    nonisolated(unsafe) static var allowsAutomaticModel = true

    static var automaticModel: ModelSelection? {
        guard allowsAutomaticModel else { return nil }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models/Qwen3.8-27B-IQ4_XS.gguf")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return ModelSelection(identifier: "qwen3.8-27b-iq4xs", displayName: "Qwen 3.8 27B(自動で読み込み)", runtime: .backburner)
    }

    func selectModel(_ model: InstalledModel) {
        library.updateSelectedProject { project in
            project.selectedModel = ModelSelection(
                identifier: model.identifier,
                displayName: model.displayName,
                runtime: model.runtime,
                capabilities: model.capabilities
            )
            project.currentActivity = "\(model.displayName)を使う準備ができました"
            project.activity.insert(
                ActivityEvent(
                    title: "AIモデルを選択しました",
                    detail: "\(model.displayName) ・ \(model.runtime.rawValue)",
                    kind: .verification
                ),
                at: 0
            )
        }
        persist(successMessage: "AIモデルを接続しました")
    }

    func disconnectModel() {
        if isGeneratingSelectedProject {
            stopGeneration()
        }
        library.updateSelectedProject { project in
            project.selectedModel = nil
            project.currentActivity = "AIモデルの接続を待っています"
        }
        persist(successMessage: "AIモデルの接続を解除しました")
    }
}
