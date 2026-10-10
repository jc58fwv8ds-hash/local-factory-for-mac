import Foundation
import HarnessCore

/// Explicit offline fixtures exercise the production edit/validation path, not model quality.
struct PilotResponseSource {
    enum Scenario: String { case success, limit, interrupted, reviewRepair, reviewLimit }
    let modelIdentifier: String
    let scenario: Scenario?
    private let replacement: String?

    init(arguments: [String]) throws {
        if arguments.count == 4, !arguments[3].hasPrefix("--") {
            modelIdentifier = arguments[3]
            scenario = nil
            replacement = nil
        } else if arguments.count == 7, arguments[3] == "--replay-source",
                  let scenario = Scenario(rawValue: arguments[6]) {
            guard arguments[5] == "--scenario" else { throw FixtureError.arguments }
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: arguments[4]))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 60_001) ?? Data()
            guard data.count <= 60_000, let content = String(data: data, encoding: .utf8), !content.isEmpty else {
                throw FixtureError.source
            }
            self.scenario = scenario
            replacement = content
            modelIdentifier = "scripted-fixture:\(scenario.rawValue)"
        } else { throw FixtureError.arguments }
    }

    func response(attempt: Int, current: String, messages: [InferenceMessage]) throws -> String? {
        guard let scenario, let replacement else { return nil }
        if isReviewScenario { try PilotReviewFixture.verifyFeedback(messages: messages, attempt: attempt) }
        var content = scenario == .limit || (scenario == .success && attempt == 1)
            ? current + "\n// Deliberately unchanged behavior: fixture attempt \(attempt).\n"
            : replacement
        if isReviewScenario { content += "\n// Offline wiring exercise: revision \(attempt).\n" }
        return String(decoding: try JSONEncoder().encode(["content": content]), as: UTF8.self)
    }

    var isReviewScenario: Bool { scenario == .reviewRepair || scenario == .reviewLimit }

    private enum FixtureError: Error { case arguments, source }
}
