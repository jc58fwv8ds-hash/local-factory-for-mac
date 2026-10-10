import Foundation

/// Host-enforced initial bounds, not a model-generated success criterion.
public enum KernelExecutionBudget {
    public static let maximumAttemptsPerStep = 3
    public static let maximumAttemptsPerRun = 200

    static func stopReason(state: KernelState, stepID: UUID) -> String? {
        if state.attemptCounts.values.reduce(0, +) >= maximumAttemptsPerRun {
            return "この制作の実行回数が上限に達しました。結果と計画を確認してから、次の作業を決めてください。"
        }
        if state.attemptCounts[stepID, default: 0] >= maximumAttemptsPerStep {
            return "同じ作業を3回試しました。繰り返しを止め、失敗の原因と別の進め方を確認する必要があります。"
        }
        return nil
    }
}
