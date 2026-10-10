import Foundation
import Testing
@testable import HarnessExecution

struct VerifierExecutionReceiptTests {
    @Test func completenessRejectsPartialDuplicateSkippedAndUnknownOutput() {
        let green = "✔ Test sample() passed after 0.001 seconds."
        #expect(VerifierTestCompletion.completed(green, required: ["sample()"]) == ["sample()"])
        #expect(VerifierTestCompletion.completed(green, required: ["sample()", "other()"]) == nil)
        #expect(VerifierTestCompletion.completed(green + "\n" + green, required: ["sample()"]) == nil)
        #expect(VerifierTestCompletion.completed(green + "\nTest skipped", required: ["sample()"]) == nil)
        #expect(VerifierTestCompletion.completed("all tests passed", required: ["sample()"]) == nil)
        #expect(VerifierTestCompletion.completed(green, required: []) == nil)
    }

    @Test func actualIsolatedReceiptRejectsRestartAndMutations() async throws {
        let candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let base = candidate.appendingPathComponent("work/proof-receipt-" + UUID().uuidString)
        let root = base.appendingPathComponent("fixture")
        let evidence = base.appendingPathComponent("evidence")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources/ReceiptProbe"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Tests/ReceiptProbeTests"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "ReceiptProbe", targets: [
            .target(name: "ReceiptProbe"),
            .testTarget(name: "ReceiptProbeTests", dependencies: ["ReceiptProbe"])
        ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("Sources/ReceiptProbe/Value.swift")
        let test = root.appendingPathComponent("Tests/ReceiptProbeTests/Check.swift")
        let sourceText = "public let sampleValue = 9\n"
        let testText = "import Testing\nimport ReceiptProbe\n@Test func receiptSample() { #expect(sampleValue == 9) }\n"
        try sourceText.write(to: source, atomically: true, encoding: .utf8)
        try testText.write(to: test, atomically: true, encoding: .utf8)
        let adapter = IsolatedPackageExecution(candidate: candidate, root: root,
            taskID: "receipt-integration", protectedPaths: ["Tests/ReceiptProbeTests/Check.swift"])
        let issuer = VerifierExecutionReceipts(adapter: adapter, evidence: evidence)
        let receipt = try await issuer.execute(requiredTests: ["receiptSample()"])
        try await issuer.validate(receipt, requiredTests: ["receiptSample()"])
        #expect(receipt.executionOrder == ["capture", "isolatedBuild", "isolatedTest", "integrityCheck", "mint"])
        #expect(receipt.protectedHashes.count == 1)
        #expect(receipt.skippedTests.isEmpty)
        let restarted = VerifierExecutionReceipts(adapter: adapter, evidence: evidence)
        await #expect(throws: VerifierExecutionReceipts.Failure.self) {
            try await restarted.validate(receipt, requiredTests: ["receiptSample()"])
        }
        await #expect(throws: VerifierExecutionReceipts.Failure.self) {
            try await issuer.validate(receipt, requiredTests: ["neverExecuted()"])
        }
        try "public let sampleValue = 10\n".write(to: source, atomically: true, encoding: .utf8)
        await #expect(throws: VerifierExecutionReceipts.Failure.self) {
            try await issuer.validate(receipt, requiredTests: ["receiptSample()"])
        }
        try sourceText.write(to: source, atomically: true, encoding: .utf8)
        // Observed mutation is sticky: reverting bytes cannot resurrect the old receipt.
        await #expect(throws: VerifierExecutionReceipts.Failure.self) {
            try await issuer.validate(receipt, requiredTests: ["receiptSample()"])
        }
        let fresh = try await issuer.execute(requiredTests: ["receiptSample()"])
        try (testText + "// mutation\n").write(to: test, atomically: true, encoding: .utf8)
        await #expect(throws: VerifierExecutionReceipts.Failure.self) {
            try await issuer.validate(fresh, requiredTests: ["receiptSample()"])
        }
    }
}
