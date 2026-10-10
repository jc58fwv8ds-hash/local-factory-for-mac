import Foundation
import HarnessExecution
import TaskOrchestrator

extension BatchCanaryRunner {
    static func run(arguments: [String]) async throws {
        guard arguments.count == 5,
              arguments[3].range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else { throw Failure.scope }
        let output = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessCandidate/Dogfood/\(arguments[3])")
        let marker = output.appendingPathComponent("task-started")
        let existed = FileManager.default.fileExists(atPath: marker.path)
        try await TaskFinalization.run(operation: { try await runBody(arguments: arguments) }, finalize: {
            // Invalid arguments / preflight refusal / old runs must not cause new inference.
            if !existed && FileManager.default.fileExists(atPath: marker.path) {
                await finalizeHealth(output: output, key: arguments[3], model: arguments[4])
            }
        })
    }

    private static func finalizeHealth(output: URL, key: String, model: String) async {
        var health: [String: Any]
        do {
            let (measurement, verdict) = try await InferenceHealthGate.check(model: model, context: "\(key):postTask")
            health = ["measurement": TaskOrchestrator.json(measurement), "verdict": TaskOrchestrator.json(verdict), "probeCompleted": true]
        } catch {
            health = ["probeCompleted": false, "error": String(describing: error)]
        }
        health["environmentEvents"] = InferenceEnvironment.shared.events
        health["sleptSeconds"] = InferenceEnvironment.shared.sleptSeconds
        // Capability result remains untouched, including early context/discovery failures.
        // A probe exception is evidence, never allowed to mask the original task error.
        do {
            try JSONSerialization.data(withJSONObject: health, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("post-task-health.json"), options: .atomic)
        } catch { print("Post-task health persistence failed: \(error)") }
    }
}
