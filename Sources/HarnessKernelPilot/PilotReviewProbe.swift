import Foundation
import HarnessExecution

enum PilotReviewProbe {
    static func run(arguments: [String]) async throws {
        guard arguments.count == 7 else { throw ProbeError.arguments }
        let fixture = URL(fileURLWithPath: arguments[2])
        let source = URL(fileURLWithPath: arguments[3])
        let validation = URL(fileURLWithPath: arguments[4])
        let output = URL(fileURLWithPath: arguments[5])
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ProbeError.outputExists }
        let contract = try await RepairAcceptanceContract.capture(root: fixture,
            paths: ["Package.swift", "Tests/MemoryStoreTests/MemoryStoreTests.swift"])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let started = Date()
        let model = arguments[6]
        do {
            let review = try await RepairReviewGate().evaluate(contract: contract, root: source,
                validationRun: validation, target: HarnessKernelPilot.target, request: HarnessKernelPilot.request,
                reviewer: LocalRepairReviewer(model: model))
            try save(.init(model: model, seconds: Date().timeIntervalSince(started), accepted: true,
                review: review, error: nil), output: output)
            print("Review accepted; saved to \(output.path)")
        } catch {
            let review: RepairReview?
            if case RepairReviewError.notAccepted(let rejected) = error { review = rejected } else { review = nil }
            try save(.init(model: model, seconds: Date().timeIntervalSince(started), accepted: false,
                review: review, error: String(describing: error)), output: output)
            throw error
        }
    }

    private static func save(_ result: ProbeResult, output: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: output.appendingPathComponent("review-probe.json"), options: .atomic)
    }

    private enum ProbeError: Error { case arguments, outputExists }
    private struct ProbeResult: Encodable {
        let model: String
        let seconds: Double
        let accepted: Bool
        let review: RepairReview?
        let error: String?
    }
}
