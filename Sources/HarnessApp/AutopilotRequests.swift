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

    /// Requests waiting their turn, per project: a message with several things to fix becomes several runs, one after
    /// another (2026-11-12, the user: the chat and its pictures sent as they are, and the Factory does the rest, for any app).
    private(set) var queued: [UUID: [String]] = [:]
    /// How many requests the current batch of a project had, and how many ended well, for the report at the end.
    private(set) var batch: [UUID: (total: Int, done: Int, good: Int)] = [:]

    func request(_ text: String, projectID: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastText[projectID] = trimmed
        pending = Request(projectID: projectID, text: trimmed)
    }

    /// The requests of a split message not yet done well, kept across restarts, for 「続けて」 (2026-11-12: a new version
    /// of the Factory was installed mid-batch and the rest of the list was gone).
    @ObservationIgnored var store: UserDefaults = .standard
    private func unfinishedKey(_ projectID: UUID) -> String { "harness.autopilot.unfinished.\(projectID.uuidString)" }
    func unfinished(projectID: UUID) -> [String] { store.stringArray(forKey: unfinishedKey(projectID)) ?? [] }
    private func setUnfinished(_ items: [String], projectID: UUID) {
        if items.isEmpty { store.removeObject(forKey: unfinishedKey(projectID)) } else { store.set(items, forKey: unfinishedKey(projectID)) }
    }
    /// The request now running, removed from the unfinished list when it ends well.
    private var running: [UUID: String] = [:]

    /// Several requests: the first runs now, the rest wait for `ended`.
    func request(all texts: [String], projectID: UUID) {
        let items = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let first = items.first else { return }
        if items.count > 1 { setUnfinished(items, projectID: projectID) }
        running[projectID] = items.count > 1 ? first : nil
        queued[projectID] = Array(items.dropFirst())
        batch[projectID] = items.count > 1 ? (items.count, 0, 0) : nil
        request(first, projectID: projectID)
    }

    var hasWaiting: (UUID) -> Bool { { [queued] in !(queued[$0] ?? []).isEmpty } }

    /// A run of the project ended (`good` when it finished well): the next waiting request starts. Returns the batch's
    /// tally when its last request has ended.
    @discardableResult
    func ended(projectID: UUID, good: Bool) -> (total: Int, good: Int)? {
        if good, let done = running[projectID] {
            var left = unfinished(projectID: projectID)
            if let index = left.firstIndex(of: done) { left.remove(at: index) }
            setUnfinished(left, projectID: projectID)
        }
        running[projectID] = nil
        if var tally = batch[projectID] {
            tally.done += 1; tally.good += good ? 1 : 0
            batch[projectID] = tally
        }
        if var waiting = queued[projectID], !waiting.isEmpty {
            let next = waiting.removeFirst()
            queued[projectID] = waiting
            running[projectID] = next
            request(next, projectID: projectID)
            return nil
        }
        defer { batch[projectID] = nil }
        return batch[projectID].map { ($0.total, $0.good) }
    }

    func cancelWaiting(projectID: UUID) {
        queued[projectID] = nil
        batch[projectID] = nil
    }
}

/// What the app is for, given with every request from the chat (2026-11-12, the user: 「リアルタイム翻訳ということを忘れないで」).
/// The fixes made 14Translate wait for silence before translating, though its description says it translates in real time.
enum AutopilotPurpose {
    static func instruction(_ request: String, summary: String) -> String {
        let purpose = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !purpose.isEmpty else { return request }
        return request + "\n\nこのアプリの目的(直すときもこれを外さないこと。速さ・使い方・前提を含む): " + String(purpose.prefix(600))
    }
}

