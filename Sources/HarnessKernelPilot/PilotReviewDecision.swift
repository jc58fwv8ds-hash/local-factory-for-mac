import Foundation
import HarnessExecution

enum PilotReviewDecision {
    enum Outcome {
        case accepted
        case repair(RepairReviewFeedback)
        case stop(RepairReview)
    }

    /// A validated, actionable rejection can consume an already available repair attempt.
    static func evaluate(contract: RepairAcceptanceContract, source: URL, validationRun: URL,
                         reviewer: any RepairReviewing, output: URL, attempt: Int) async throws -> Outcome {
        do {
            let review = try await RepairReviewGate().evaluate(contract: contract, root: source,
                validationRun: validationRun, target: HarnessKernelPilot.target, request: HarnessKernelPilot.request,
                reviewer: reviewer)
            try save(review, output: output, attempt: attempt)
            return .accepted
        } catch RepairReviewError.notAccepted(let review) {
            try save(review, output: output, attempt: attempt)
            guard let feedback = RepairReviewFeedback(review: review, remainingAttempts: 2 - attempt) else {
                return .stop(review)
            }
            return .repair(feedback)
        }
    }

    private static func save(_ review: RepairReview, output: URL, attempt: Int) throws {
        try JSONEncoder().encode(review).write(to: output.appendingPathComponent("review-\(attempt).json"), options: .atomic)
    }
}
