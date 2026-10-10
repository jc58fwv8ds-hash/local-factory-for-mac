import Foundation
import HarnessKernelContracts

/// Advisory text only. Does not grant edit scope, approval, or another attempt.
public struct RepairReviewFeedback: Sendable {
    public let explanation: String
    private let sourceDigest: String

    public init?(review: RepairReview, remainingAttempts: Int) {
        guard remainingAttempts > 0,
              review.correctness != .insufficientEvidence, review.maintainability != .insufficientEvidence,
              review.correctness == .changesRequired || review.maintainability == .changesRequired,
              !review.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              review.explanation.utf8.count <= 8_000 else { return nil }
        explanation = review.explanation
        sourceDigest = review.sourceDigest
    }

    public func verifySource(root: URL) async throws {
        guard try await ValidationSourceIdentity.digest(root: root) == sourceDigest else {
            throw KernelError.invalidEvidence
        }
    }
}
