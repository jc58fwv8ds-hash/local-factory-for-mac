import Foundation

/// The agent screen's conversation (2026-11-02). Shaped after Codex's protocol (openai/codex, codex-rs/docs/protocol_v1.md):
/// the agent core takes requests, approvals, answers and interrupts, and gives back events; every front end (the Mac
/// screen, a paired iPhone) drives the same core, so the safety checks of `ComputerUseRisk` stay in one place.
public enum AgentSource: String, Codable, Sendable {
    case mac
    case remote
}

public struct AgentEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// What the user asked (typed on the Mac or sent from a device).
        case request
        /// One action of the agent and what happened.
        case step
        /// An action that waits for the user's yes or no.
        case approval
        /// The agent asks the user; the next request answers it.
        case question
        /// How the request ended.
        case outcome
    }

    public let id: UUID
    public let kind: Kind
    public let text: String
    public let detail: String
    public let source: AgentSource
    public let date: Date

    public init(id: UUID = UUID(), kind: Kind, text: String, detail: String = "", source: AgentSource = .mac, date: Date = Date()) {
        self.id = id; self.kind = kind; self.text = text; self.detail = detail; self.source = source; self.date = date
    }
}

/// Ops into the core (Codex's Submission queue).
public enum AgentOp: Equatable, Sendable {
    case request(String, AgentSource)
    case approve(UUID, Bool)
    case interrupt
}

public enum AgentGoal {
    /// The goal for a new request. After the agent asked a question, the new request is the answer: the earlier goal, the
    /// question and the answer go together, so the agent continues instead of starting over.
    public static func compose(request: String, entries: [AgentEntry]) -> String {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        // A request entry keeps the whole goal it ran with in `detail`; an outcome that waits for the user keeps its question there.
        guard let last = entries.last, last.kind == .outcome,
              let previous = entries.last(where: { $0.kind == .request }) else { return text }
        // Finished: the next request may build on the result (「それを開いて」, 2026-11-04), so the last one goes along.
        guard !last.detail.isEmpty else {
            return """
            \(text)
            (直前の依頼: \(previous.text.prefix(200)) / その結果: \(last.text.prefix(400)))
            今回の依頼が直前の結果の続きなら、それを踏まえる。別の話なら無視する。
            """
        }
        let goal = previous.detail.isEmpty ? previous.text : previous.detail
        return """
        \(goal)
        (前回はここで止まりました: \(last.detail))
        ユーザーの答え: \(text)
        """
    }
}
