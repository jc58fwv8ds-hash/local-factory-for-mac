import Foundation
import CryptoKit
import HarnessCore

public enum RuntimeRepair {
    /// Decoded final contents, sorted by path: independent of JSON order/edit primitive.
    public static func fingerprint(_ proposals: [FileChangeProposal]) -> String {
        let rows = proposals.sorted { $0.relativePath < $1.relativePath }.map {
            [$0.relativePath, $0.originalContent, $0.proposedContent]
        }
        let data = try! JSONEncoder().encode(rows)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    /// Deliberately accepts no raw output, stack, assertion or hidden-test source.
    public static func feedback(verdict: VerificationAdjudication.Verdict, diff: String) -> String {
        """
        Runtime-guided repair: compilation passed but verification failed.
        Classification: \(verdict.kind.rawValue)
        process started: \(verdict.processStarted)
        Termination: \(verdict.terminationType)
        Isolation denial: \(verdict.isolationDenial)
        No specific cause is inferred. Reconsider your own implementation against the accepted plan.
        The previous edit has been rolled back. Return a new complete proposal against the original source.
        Do not request additional files or broaden editable scope.
        Your previous diff:
        \(diff)
        """
    }
}
