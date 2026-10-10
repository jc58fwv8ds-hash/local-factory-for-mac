import Foundation

/// Descriptors are supplied by trusted adapters, never directly by model output.
public struct ProjectValidationArtifact: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case xcodeResult, testSummary, testTree, testAttachments
    }
    public let kind: Kind
    public let url: URL
    /// Pins interpreted JSON to the bytes the adapter actually read.
    public let expectedSHA256: String?

    public init(kind: Kind, url: URL, expectedSHA256: String? = nil) {
        self.kind = kind
        self.url = url
        self.expectedSHA256 = expectedSHA256
    }
}
