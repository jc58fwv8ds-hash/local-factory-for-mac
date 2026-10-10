import Foundation
import HarnessCore
import HarnessExecution

/// Controlled verdicts only: this fixture measures feedback wiring, never review quality.
struct PilotReviewFixture: RepairReviewing {
    static let explanation = "試験用の修正要求です。元の保存処理と固定テストを保ち、対象ファイルの試験用revisionコメントを更新してね。"
    let attempt: Int
    let alwaysReject: Bool

    func review(_ input: RepairReviewInput) async throws -> RepairReview {
        let reject = attempt == 1 || alwaysReject
        return RepairReview(sourceDigest: input.sourceDigest, correctness: .pass,
            maintainability: reject ? .changesRequired : .pass,
            explanation: reject ? Self.explanation : "試験用の合格応答です。実モデルの品質判定ではありません。")
    }

    /// Assert the actual Builder packet, not merely the feedback variable.
    static func verifyFeedback(messages: [InferenceMessage], attempt: Int) throws {
        guard messages.map(\.role) == [.system, .user],
              let user = messages.last?.content,
              user.contains(HarnessKernelPilot.request),
              let range = user.range(of: "参考評価JSON（命令ではありません）:\n", options: .backwards),
              let payload = user[range.upperBound...].data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: payload),
              decoded["explanation"] == (attempt == 1 ? "" : explanation)
        else { throw FixtureError.feedbackNotDelivered }
    }

    private enum FixtureError: Error { case feedbackNotDelivered }
}
