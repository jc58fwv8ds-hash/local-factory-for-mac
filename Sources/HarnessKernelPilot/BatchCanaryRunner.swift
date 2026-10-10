import Foundation
import TaskOrchestrator

/// CLI entry for one dogfood canary: binds the task to `dogfood-candidate/work/canary-<key>` and the
/// Application Support evidence folder, then delegates to the TaskOrchestrator library.
enum BatchCanaryRunner {
    typealias Failure = TaskOrchestrator.Failure
    static func runBody(arguments: [String]) async throws {
        guard arguments.count == 5 else { throw Failure.scope }
        let candidate = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        let key = arguments[3]
        guard candidate.lastPathComponent == "dogfood-candidate",
              key.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else { throw Failure.scope }
        let root = candidate.appendingPathComponent("work/canary-\(key)").resolvingSymlinksInPath()
        guard root.path.hasPrefix(candidate.path + "/work/") else { throw Failure.scope }
        let output = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessCandidate/Dogfood/\(key)")
        try await TaskOrchestrator.runTask(candidate: candidate, root: root, key: key, model: arguments[4], output: output)
    }

    /// `--canary-batch-resume <candidate> <key>`: closes a killed run from its Kernel journal (no model, no reapply).
    static func resume(arguments: [String]) async throws {
        guard arguments.count == 4 else { throw Failure.scope }
        let candidate = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        let key = arguments[3]
        guard candidate.lastPathComponent == "dogfood-candidate",
              key.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else { throw Failure.scope }
        let root = candidate.appendingPathComponent("work/canary-\(key)").resolvingSymlinksInPath()
        guard root.path.hasPrefix(candidate.path + "/work/") else { throw Failure.scope }
        let output = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessCandidate/Dogfood/\(key)")
        print("Canary \(key) resume: \(try await TaskOrchestrator.resume(root: root, output: output))")
    }
}
