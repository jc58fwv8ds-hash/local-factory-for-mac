import Foundation

/// Execution truth of a task's rollback. Once a rollback was attempted, later bookkeeping
/// (for example a failure recorded by a subsequent stage) can never downgrade it to
/// NOT_NEEDED or NOT_ATTEMPTED; a failed attempt is never hidden by a later success.
public enum RollbackOutcome: String, Codable, Sendable, CaseIterable {
    case NOT_ATTEMPTED, NOT_NEEDED, ATTEMPTED_SUCCESS, ATTEMPTED_FAIL

    /// Maps the runner's rollback detail strings ("PASS", "FAILED", "INCOMPLETE", ...).
    public init(detail: String) {
        switch detail {
        case "PASS", Self.ATTEMPTED_SUCCESS.rawValue: self = .ATTEMPTED_SUCCESS
        case "NOT_NEEDED": self = .NOT_NEEDED
        case "NOT_ATTEMPTED": self = .NOT_ATTEMPTED
        default: self = .ATTEMPTED_FAIL
        }
    }

    private var rank: Int {
        switch self {
        case .NOT_ATTEMPTED: 0
        case .NOT_NEEDED: 1
        case .ATTEMPTED_SUCCESS: 2
        case .ATTEMPTED_FAIL: 3
        }
    }

    public static func merge(_ current: RollbackOutcome?, _ next: RollbackOutcome) -> RollbackOutcome {
        guard let current else { return next }
        return next.rank > current.rank ? next : current
    }
}
