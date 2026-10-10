import Foundation
import TaskOrchestrator
import HarnessCore
import HarnessExecution

enum LocalVerifierExperiment {
    static func run(_ arguments: [String]) async throws {
        guard arguments.count == 5 else { throw LocalRequirementVerifier.Failure.invalid }
        let request = try JSONDecoder().decode(RequirementVerification.Request.self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let model = arguments[3], output = URL(fileURLWithPath: arguments[4])
        guard !FileManager.default.fileExists(atPath: output.path) else { throw LocalRequirementVerifier.Failure.invalid }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let start = Date(), prompt = try LocalRequirementVerifier.prompt(request)
        try Data(prompt.utf8).write(to: output.appendingPathComponent("prompt.txt"), options: .withoutOverwriting)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var record: [String: Any] = ["arm": model == request.builderModel ? "same-model verifier" : "different-model verifier",
            "model": model, "taskID": request.taskID, "offlineOnly": true, "automaticFinalization": false]
        do {
            let raw = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                messages: [.init(role: .user, content: prompt)], maximumOutputTokens: 2048,
                structuredOutput: .localRequirementReview))
            try Data(raw.utf8).write(to: output.appendingPathComponent("raw-response.json"), options: .withoutOverwriting)
            let response = try JSONDecoder().decode(LocalRequirementVerifier.Response.self, from: Data(raw.utf8))
            let report = try LocalRequirementVerifier.report(response, request: request, model: model)
            try encoder.encode(report).write(to: output.appendingPathComponent("report.json"), options: .withoutOverwriting)
            let decision = RequirementVerification.decide(report, for: request)
            try encoder.encode(decision).write(to: output.appendingPathComponent("decision.json"), options: .withoutOverwriting)
            record["outcome"] = decision.outcome.rawValue
        } catch { record["outcome"] = "INVALID_OR_UNAVAILABLE"; record["error"] = String(describing: error) }
        record["elapsed"] = Date().timeIntervalSince(start)
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"), options: .withoutOverwriting)
        print("Local verifier experiment: \(record["outcome"] ?? "unknown")")
    }
}
