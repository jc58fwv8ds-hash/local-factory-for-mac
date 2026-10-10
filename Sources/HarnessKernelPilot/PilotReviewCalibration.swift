import CryptoKit
import Foundation
import HarnessExecution

/// Isolated grader calibration: never produces production completion evidence.
enum PilotReviewCalibration {
    static func run(arguments: [String]) async throws {
        guard arguments.count == 5 else { throw CalibrationError.arguments }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: arguments[2]))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 60_001) ?? Data()
        guard data.count <= 60_000, let source = String(data: data, encoding: .utf8), !source.isEmpty else {
            throw CalibrationError.source
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let output = URL(fileURLWithPath: arguments[3])
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CalibrationError.outputExists }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let started = Date()
        let model = arguments[4]
        let input = RepairReviewInput(request: HarnessKernelPilot.request, source: source, sourceDigest: digest,
            validationReference: "No executed tests supplied; static code review only.")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(input).write(to: output.appendingPathComponent("input.json"), options: .atomic)
        do {
            let review = try await LocalRepairReviewer(model: model).review(input)
            let valid = review.sourceDigest == digest && !review.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let outcome = valid && review.correctness == .changesRequired ? "rejected-defective-case"
                : review.permitsCompletion(for: digest) ? "missed-defect" : "inconclusive"
            try save(.init(model: model, seconds: Date().timeIntervalSince(started), outcome: outcome,
                review: review, error: nil), to: output, encoder: encoder)
            print("Calibration: \(outcome); saved to \(output.path)")
        } catch {
            try save(.init(model: model, seconds: Date().timeIntervalSince(started), outcome: "error",
                review: nil, error: String(describing: error)), to: output, encoder: encoder)
            throw error
        }
    }

    private static func save(_ result: Result, to output: URL, encoder: JSONEncoder) throws {
        try encoder.encode(result).write(to: output.appendingPathComponent("calibration.json"), options: .atomic)
    }
    private struct Result: Encodable {
        let model: String
        let seconds: Double
        let outcome: String
        let review: RepairReview?
        let error: String?
    }
    private enum CalibrationError: Error { case arguments, source, outputExists }
}
