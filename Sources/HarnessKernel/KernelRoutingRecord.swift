import Foundation
import HarnessKernelContracts

/// Versioned evidence carried by the existing decision event. It is never a grant
/// to execute: availability and permissions must be checked again before dispatch.
public struct KernelRoutingRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let stepID: UUID
    public let revision: Int
    public let decision: KernelRoutingPolicy.Decision

    private static let prefix = "harness-routing-v1:"

    init(stepID: UUID, revision: Int, decision: KernelRoutingPolicy.Decision) {
        version = 1
        self.stepID = stepID
        self.revision = revision
        self.decision = decision
    }

    func encodedDecision() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self.prefix + String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(_ payload: KernelEventPayload) throws -> Self? {
        guard case .decisionRecorded(let text) = payload,
              text.hasPrefix("harness-routing-") else { return nil }
        guard text.hasPrefix(prefix) else { throw KernelError.unsupportedSchema }
        let record = try JSONDecoder().decode(Self.self, from: Data(text.dropFirst(prefix.count).utf8))
        guard record.version == 1 else { throw KernelError.unsupportedSchema }
        return record
    }
}
