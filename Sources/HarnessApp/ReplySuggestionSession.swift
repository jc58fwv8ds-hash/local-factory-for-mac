import Foundation
import HarnessCore
import Observation

/// Transient suggestion lifecycle. Does not mutate projects, drafts, or production permissions.
@MainActor
@Observable
final class ReplySuggestionSession {
    private(set) var context: ReplySuggestionContext?
    private(set) var suggestions: [ReplySuggestion] = []
    private(set) var isLoading = false
    private(set) var message: String?
    @ObservationIgnored private let service: any ReplySuggestionProviding
    @ObservationIgnored private var generationID: UUID?
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(service: any ReplySuggestionProviding) { self.service = service }

    func synchronize(context: ReplySuggestionContext?) {
        guard self.context != context else { return }
        cancel()
        self.context = context
        suggestions = []
        message = nil
    }

    func generate(for context: ReplySuggestionContext) {
        synchronize(context: context)
        cancel()
        suggestions = []
        message = nil
        isLoading = true
        let id = UUID()
        generationID = id
        task = Task { [weak self, service] in
            do {
                let suggestions = try await service.suggestions(for: context)
                try Task.checkCancellation()
                guard let self, self.generationID == id, self.context == context else { return }
                self.suggestions = suggestions
                self.finish()
            } catch {
                guard let self, !Task.isCancelled, self.generationID == id else { return }
                self.message = (error as? ReplySuggestionError)?.localizedDescription
                    ?? "今は候補を作れませんでした。AIの接続を確認するか、そのまま自分の言葉で頼んでね。"
                self.finish()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generationID = nil
        isLoading = false
    }

    func suggestion(id: UUID, context: ReplySuggestionContext) -> ReplySuggestion? {
        guard self.context == context, !isLoading else { return nil }
        return suggestions.first { $0.id == id }
    }

    private func finish() {
        isLoading = false
        generationID = nil
        task = nil
    }
}
