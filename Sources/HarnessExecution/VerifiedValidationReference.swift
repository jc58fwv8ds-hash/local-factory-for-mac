import Foundation
import HarnessKernelContracts
import HarnessKernelPersistence

/// Exports a child receipt reference only after checking evidence and current source.
public enum VerifiedValidationReference {
    public static func read(runDirectory: URL, root: URL) async throws -> String {
        guard try await ValidationRecoveryService().inspect(runDirectory: runDirectory, root: root) == .verified else {
            throw KernelError.invalidEvidence
        }
        let journal = try FileKernelJournal(directory: runDirectory.appendingPathComponent("events"))
        let events = try journal.read()
        guard case .planned(let plan) = events.first?.payload,
              plan.requirements.contains(where: { $0.kind == .build }),
              plan.requirements.contains(where: { $0.kind == .testExecution }) else {
            throw KernelError.invalidEvidence
        }
        let references = events.compactMap { event -> String? in
            if case .verificationRecorded(let evidence) = event.payload { return evidence.reportReference }
            return nil
        }
        guard let reference = references.first, Set(references).count == 1,
              try await ValidationRecoveryService().inspect(runDirectory: runDirectory, root: root) == .verified,
              try journal.read() == events else { throw KernelError.invalidEvidence }
        return reference
    }
}
