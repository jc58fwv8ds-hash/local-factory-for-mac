import Foundation
import HarnessCore
import HarnessExecution

extension TaskOrchestrator {
    /// The slower checks after the card is shown (2026-10-09): the example check and the examiner run on the finished,
    /// tested result, so the user sees the proposal ~5 minutes sooner and the 要確認 lines arrive while they read it.
    /// Report only: the examiner's fix round is not run here (on C2 it was never accepted), and nothing here changes the
    /// proposal. Every change is checked (2026-10-10): the checks no longer delay the card, and on C2 two of four false
    /// successes carried no risk signal. Returns the updated run record.
    package static func postChecks(candidate: URL, root: URL, model: String, objective: String,
                                   originals: [String: String], output: URL, seeds: [[String: String]] = []) async -> URL {
        let result = output.appendingPathComponent("result.json")
        let values = (try? JSONSerialization.jsonObject(with: Data(contentsOf: result))) as? [String: Any] ?? [:]
        let record = BatchRunRecord(url: result, start: Date(), values: values)
        let task = try? JSONDecoder().decode(Task.self, from: Data(contentsOf: root.appendingPathComponent("task.json")))
        var visibleTests: [String: String] = [:]
        for path in task?.protectedFiles ?? [] where path.hasSuffix(".swift") && path.split(separator: "/").contains("Tests") {
            visibleTests[path] = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let sources = root.appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        let permitted = files.filter { $0.pathExtension == "swift" }
            .map { "Sources/" + $0.resolvingSymlinksInPath().path.dropFirst(sources.resolvingSymlinksInPath().path.count + 1) }.sorted()
        let directory = output.appendingPathComponent("post-checks")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await ExampleCheckStage.run(candidate: candidate, root: root, directory: directory, model: model, objective: objective,
                                    originals: originals, visibleTests: visibleTests, permitted: permitted, record: record,
                                    seeds: seeds.compactMap { seed in
                                        guard let expression = seed["expression"], !expression.isEmpty else { return nil }
                                        return .init(situation: seed["situation"] ?? "", quantity: seed["quantity"] ?? "",
                                                     setup: seed["setup"] ?? "", expression: expression, alternatives: [])
                                    })
        do {
            _ = try await BatchExaminerStage.examine(candidate: candidate, root: root, directory: directory, model: model,
                objective: objective, originals: originals, visibleTests: visibleTests, permitted: permitted, allowed: true,
                record: record)
        } catch {
            record["examinerCheck"] = ["outcome": "examinerUnavailable (\(error))"]
        }
        try? record.save()
        return result
    }
}
