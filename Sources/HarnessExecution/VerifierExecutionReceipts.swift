import Foundation

/// Phase 3 provenance boundary. Only this actor can mint an admissible receipt, after the
/// existing concrete isolation gate runs. Fixture JSON cannot construct or restore one.
/// Restart currently fails closed: persisted exports are audit data, not authority.
public actor VerifierExecutionReceipts {
    public enum Failure: Error { case invalidContract, changedInputs, incompleteTests, unknownReceipt }

    public struct Receipt: Encodable, Sendable {
        public let id: UUID
        public let taskID: String
        public let command: [String]
        public let sourceDigest: String
        public let testDigest: String
        public let executionOrder: [String]
        public let startedAt: Date
        public let finishedAt: Date
        public let exitCode: Int32
        public let requiredTestsExecuted: [String]
        public let skippedTests: [String]
        public let protectedHashes: [String: String]
        public let outputDigest: String
        fileprivate let inputHashes: [String: String]

        fileprivate init(adapter: IsolatedPackageExecution, inputs: [String: String], tests: [String: String],
                         executed: [String], output: String, startedAt: Date) {
            id = UUID(); taskID = adapter.taskID
            command = ["swift build", "swift test"]
            sourceDigest = VerifierExecutionReceipts.digest(inputs)
            testDigest = VerifierExecutionReceipts.digest(tests)
            executionOrder = ["capture", "isolatedBuild", "isolatedTest", "integrityCheck", "mint"]
            self.startedAt = startedAt; finishedAt = Date(); exitCode = 0
            requiredTestsExecuted = executed.sorted(); skippedTests = []; protectedHashes = tests
            outputDigest = ValidationSourceIdentity.hash(Data(output.utf8)); inputHashes = inputs
        }
    }

    private let adapter: IsolatedPackageExecution
    private let evidence: URL
    private var issued: [UUID: Receipt] = [:]
    private var running = false
    private var inputEpoch = UUID()

    public init(adapter: IsolatedPackageExecution, evidence: URL) {
        self.adapter = adapter; self.evidence = evidence
    }

    /// `requiredTests` is a frozen Harness contract, not a model-produced test list.
    public func execute(requiredTests: Set<String>) async throws -> Receipt {
        guard !running, !requiredTests.isEmpty, requiredTests.count <= 256,
              !adapter.protectedPaths.isEmpty,
              adapter.root == adapter.root.standardizedFileURL.resolvingSymlinksInPath(),
              adapter.root.path.hasPrefix(adapter.candidate.path + "/work/"),
              evidence == evidence.standardizedFileURL.resolvingSymlinksInPath(),
              evidence.path != adapter.root.path,
              !evidence.standardizedFileURL.path.hasPrefix(adapter.root.path + "/") else {
            throw Failure.invalidContract
        }
        running = true
        defer { running = false }
        let epoch = inputEpoch
        let before = try snapshot()
        let protected = before.filter { adapter.protectedPaths.contains($0.key) }
        guard protected.count == Set(adapter.protectedPaths).count else { throw Failure.invalidContract }
        let start = Date()
        _ = try await GeneratedCodeExecutionGate.executePackage(adapter, operation: .build, evidence: evidence)
        guard epoch == inputEpoch, before == (try snapshot()) else { throw Failure.changedInputs }
        let result = try await GeneratedCodeExecutionGate.executePackage(adapter, operation: .test, evidence: evidence)
        guard epoch == inputEpoch, before == (try snapshot()) else { throw Failure.changedInputs }
        guard !result.outputWasTruncated,
              let executed = VerifierTestCompletion.completed(result.output, required: requiredTests) else {
            throw Failure.incompleteTests
        }
        let receipt = Receipt(adapter: adapter, inputs: before, tests: protected, executed: executed,
                              output: result.output, startedAt: start)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        // Export is audit-only: there is intentionally no decoder/import-to-authority path.
        try encoder.encode(receipt).write(to: evidence.appendingPathComponent("proof-" + receipt.id.uuidString + ".json"),
                                          options: .atomic)
        issued[receipt.id] = receipt
        return receipt
    }

    /// Absence, another issuer, mutation (including tests), or restart => no admissible evidence.
    public func validate(_ receipt: Receipt, requiredTests: Set<String>) throws {
        guard !requiredTests.isEmpty, let original = issued[receipt.id],
              original.sourceDigest == receipt.sourceDigest,
              original.testDigest == receipt.testDigest,
              requiredTests.isSubset(of: Set(original.requiredTestsExecuted)) else {
            throw Failure.unknownReceipt
        }
        do {
            guard original.inputHashes == (try snapshot()) else { throw Failure.changedInputs }
        } catch {
            issued.removeValue(forKey: receipt.id)
            throw error
        }
    }

    /// A recorded source/test write invalidates evidence even if it restores identical bytes.
    /// The edit orchestration integration must call this before applying another edit.
    public func invalidateForInputWrite() { inputEpoch = UUID(); issued.removeAll() }

    private func snapshot() throws -> [String: String] {
        let values = try ExecutionIntegritySnapshot.capture(adapter.root,
            excluding: [".harness-execution", ".harness-execution-host.lock"])
        guard !values.isEmpty, !values.values.contains(where: { $0.hasPrefix("symlink:") }) else {
            throw Failure.invalidContract
        }
        return values
    }

    fileprivate static func digest(_ hashes: [String: String]) -> String {
        // Sorted JSON avoids delimiter ambiguities in filenames.
        let data = try! JSONEncoder().encode(hashes.keys.sorted().map { [$0, hashes[$0]!] })
        return ValidationSourceIdentity.hash(data)
    }
}

/// Conservative completion extraction. Every required identity must complete exactly once;
/// skips, expected failures, duplicate names, truncation or unknown formats never imply green.
/// Output is observed from protected, hash-bound test execution, not fixture receipt JSON.
enum VerifierTestCompletion {
    static func completed(_ output: String, required: Set<String>) -> [String]? {
        guard !required.isEmpty else { return nil }
        var passes: [String: Int] = [:]
        let forbidden = ["skipped", "expected failure", "expectedfailure", "failed after", "recorded an issue"]
        for line in output.components(separatedBy: "\n") {
            if forbidden.contains(where: { line.lowercased().contains($0) }) { return nil }
            if let match = capture(line, #"^Test Case '-\[([^\]]+)\]' passed \("#) {
                passes[match, default: 0] += 1
            } else if let match = capture(line, #"^✔ Test (.+) passed after [0-9]"#) {
                passes[match, default: 0] += 1
            }
        }
        guard required.allSatisfy({ passes[$0] == 1 }) else { return nil }
        return passes.keys.sorted()
    }

    private static func capture(_ line: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }
}
