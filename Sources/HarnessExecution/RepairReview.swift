import Foundation
import HarnessCore
import HarnessKernelContracts

public struct RepairReviewInput: Encodable, Sendable {
    public let request: String
    public let source: String
    public let sourceDigest: String
    public let validationReference: String

    public init(request: String, source: String, sourceDigest: String, validationReference: String) {
        self.request = request
        self.source = source
        self.sourceDigest = sourceDigest
        self.validationReference = validationReference
    }
}

public struct RepairReview: Codable, Sendable {
    public enum Verdict: String, Codable, Sendable { case pass, changesRequired, insufficientEvidence }
    public let sourceDigest: String
    public let correctness: Verdict
    public let maintainability: Verdict
    public let explanation: String

    public init(sourceDigest: String, correctness: Verdict, maintainability: Verdict, explanation: String) {
        self.sourceDigest = sourceDigest
        self.correctness = correctness
        self.maintainability = maintainability
        self.explanation = explanation
    }

    public func permitsCompletion(for digest: String) -> Bool {
        sourceDigest == digest && correctness == .pass && maintainability == .pass
            && !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && explanation.utf8.count <= 8_000
    }
}

public protocol RepairReviewing: Sendable {
    func review(_ input: RepairReviewInput) async throws -> RepairReview
}

/// A reviewer may veto completion, never override deterministic verification.
public struct RepairReviewGate: Sendable {
    public init() {}

    public func evaluate(contract: RepairAcceptanceContract, root: URL, validationRun: URL,
                         target: String, request: String, reviewer: any RepairReviewing) async throws -> RepairReview {
        let evaluator = RepairAcceptanceEvaluator()
        let reference = try await evaluator.evaluate(contract: contract, root: root, validationRun: validationRun)
        let digest = try await ValidationSourceIdentity.digest(root: root)
        let document = try await ProjectFileEditor().load(rootPath: root.path, relativePath: target)
        guard document.content.utf8.count <= 60_000 else { throw KernelError.invalidEvidence }
        let review = try await reviewer.review(.init(request: request, source: document.content,
            sourceDigest: digest, validationReference: reference))
        try Task.checkCancellation()
        guard review.sourceDigest == digest,
              try await ValidationSourceIdentity.digest(root: root) == digest,
              try await evaluator.evaluate(contract: contract, root: root, validationRun: validationRun) == reference else {
            throw RepairReviewError.evidenceChanged
        }
        guard review.permitsCompletion(for: digest) else { throw RepairReviewError.notAccepted(review) }
        return review
    }
}

public enum RepairReviewError: Error { case notAccepted(RepairReview), evidenceChanged, responseTooLarge, timeout }
