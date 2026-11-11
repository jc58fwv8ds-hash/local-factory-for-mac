import Foundation
import Observation

/// A request typed in the code chat to be built 「おまかせ」 (2026-11-10, the user: 「開発経験がないユーザーも君とのここでの
/// やり取りみたいにパイプコーディングできる様に」): the inspector opens the file sheet, plans the files and runs them.
@MainActor
@Observable
final class AutopilotRequests {
    static let shared = AutopilotRequests()

    struct Request: Equatable, Identifiable {
        let id = UUID()
        let projectID: UUID
        let text: String
    }

    var pending: Request?
    /// The last request per project, for 「続けて」 (2026-11-10).
    private(set) var lastText: [UUID: String] = [:]

    func request(_ text: String, projectID: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastText[projectID] = trimmed
        pending = Request(projectID: projectID, text: trimmed)
    }
}
