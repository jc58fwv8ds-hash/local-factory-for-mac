import Foundation

/// Resume data is evidence, never authority to execute an external provider.
public struct StructuredProposalCheckpoint: Codable, Sendable {
    public struct Attempt: Codable, Sendable {
        public let id: UUID
        public let startedAt: Date
        public var response: String?
        public var outcome: String
    }
    public let schemaVersion: Int
    public let rootPath: String
    public let target: String
    public let model: String
    public let objective: String
    public let originalContent: String
    public var attempts: [Attempt]
    public var phase: String
}
