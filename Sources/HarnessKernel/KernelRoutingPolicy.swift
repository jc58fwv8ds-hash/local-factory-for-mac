import Foundation

/// Pure planning policy, not an execution authorization. Providers must separately
/// enforce credentials, billing, permissions, current availability and task budgets.
public enum KernelRoutingPolicy {
    public enum Work: String, Codable, Sendable {
        case deterministic, simpleAnalysis, focusedEdit, crossBoundary
    }

    public enum Route: String, Codable, Sendable {
        case tools, local, sol, astra, blocked
    }

    public struct Decision: Codable, Equatable, Sendable {
        public let route: Route
        public let independentReviewRequired: Bool
        public let reason: String
    }

    /// Availability means a verified capability for this task, not installation
    /// or a cached model name. Unknown subscription safety must be passed as false.
    public static func decide(
        work: Work,
        localCompatible: Bool,
        subscriptionDispatchVerified: Bool,
        solAvailable: Bool,
        astraAvailable: Bool,
        materialRisk: Bool = false,
        repeatedFailures: Int = 0
    ) -> Decision {
        let review = materialRisk || repeatedFailures >= 2
        // Repeated failure is a stop/review condition, never an automatic upgrade.
        if repeatedFailures >= 2 {
            return Decision(route: .blocked, independentReviewRequired: true,
                            reason: "同じ失敗が続いています。再試行を止めて原因を確認します。")
        }
        if work == .deterministic {
            return Decision(route: .tools, independentReviewRequired: review,
                            reason: "AIを使わず、決められた手順で確認できます。")
        }
        if work == .simpleAnalysis && localCompatible {
            return Decision(route: .local, independentReviewRequired: review,
                            reason: "この作業に対応したローカルモデルを利用します。")
        }
        guard subscriptionDispatchVerified else {
            return Decision(route: .blocked, independentReviewRequired: review,
                            reason: "認証・課金方式・実行互換性の確認が済むまで外部モデルを呼びません。")
        }
        let route: Route = work == .crossBoundary
            ? (astraAvailable ? .astra : .blocked)
            : (solAvailable ? .sol : .blocked)
        return Decision(route: route, independentReviewRequired: review,
                        reason: route == .blocked
                            ? "必要なモデルを利用できません。別の有料経路へは切り替えません。"
                            : "作業の範囲に合う確認済みモデルを選びました。実行前に権限を再確認します。")
    }
}
