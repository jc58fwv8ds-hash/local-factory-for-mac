import Foundation

/// Strict v0.1.0 xcresulttool boundary. Missing required fields and unknown results fail closed.
public struct XcodeTestSummary: Decodable, Sendable {
    public let result: String
    public let totalTestCount: Int
    public let passedTests: Int
    public let failedTests: Int
    public let skippedTests: Int
    public let expectedFailures: Int
    private let devicesAndConfigurations: [Configuration]

    public func passed(on deviceID: UUID) -> Bool {
        result == "Passed" && totalTestCount > 0 && passedTests == totalTestCount
            && failedTests == 0 && skippedTests == 0 && expectedFailures == 0
            && !devicesAndConfigurations.isEmpty
            && devicesAndConfigurations.allSatisfy {
                UUID(uuidString: $0.device.deviceId) == deviceID
                    && $0.device.platform == "iOS Simulator" && $0.passedTests > 0
                    && $0.failedTests == 0 && $0.skippedTests == 0 && $0.expectedFailures == 0
            }
    }

    private struct Configuration: Decodable, Sendable {
        let device: Device
        let passedTests, failedTests, skippedTests, expectedFailures: Int
    }
    private struct Device: Decodable, Sendable { let deviceId, platform: String }
}

/// A host-defined acceptance condition, not an LLM assertion. Screenshots alone never satisfy this.
public struct XcodeUIAcceptance: Codable, Equatable, Sendable {
    public let criterion: String
    public let deviceID: UUID
    public let testIdentifiers: [String]

    public init(criterion: String, deviceID: UUID, testIdentifiers: [String]) {
        self.criterion = criterion
        self.deviceID = deviceID
        self.testIdentifiers = testIdentifiers
    }

    public var isValid: Bool {
        !criterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !testIdentifiers.isEmpty && testIdentifiers.count <= 100
            && testIdentifiers.allSatisfy { !$0.isEmpty }
            && Set(testIdentifiers).count == testIdentifiers.count
    }

    public func isSatisfied(summary: Data, tests: Data) throws -> Bool {
        guard isValid, summary.count <= 1_048_576, tests.count <= 1_048_576 else { return false }
        let summary = try JSONDecoder().decode(XcodeTestSummary.self, from: summary)
        guard summary.passed(on: deviceID) else { return false }
        let tree = try JSONDecoder().decode(TestTree.self, from: tests)
        var results: [String: [String]] = [:]
        func visit(_ nodes: [TestNode], inUIBundle: Bool, depth: Int) throws {
            guard depth <= 32 else { throw XcodeEvidenceError.invalidResult }
            for node in nodes {
                let isUI = inUIBundle || node.nodeType == "UI test bundle"
                guard node.result == nil || node.result == "Passed" else { throw XcodeEvidenceError.invalidResult }
                if isUI, node.nodeType == "Test Case", let id = node.nodeIdentifier {
                    results[id, default: []].append(node.result ?? "Unknown")
                }
                try visit(node.children ?? [], inUIBundle: isUI, depth: depth + 1)
            }
        }
        try visit(tree.testNodes, inUIBundle: false, depth: 0)
        return testIdentifiers.allSatisfy { results[$0] == ["Passed"] }
    }
}

private struct TestTree: Decodable { let testNodes: [TestNode] }
private struct TestNode: Decodable {
    let nodeType: String
    let nodeIdentifier: String?
    let result: String?
    let children: [TestNode]?
}

public enum XcodeEvidenceError: Error { case invalidResult, exportFailed }
