import Foundation
import TaskOrchestrator
import HarnessCore
import HarnessExecution
import HarnessKernel

/// Bounded proposal-only model evaluation. Models cannot edit acceptance tests or run tools.
enum SmallCanaryRunner {
    enum Failure: Error { case arguments, scope, alreadyStarted }
    static func run(arguments: [String]) async throws {
        guard arguments.count == 5 else { throw Failure.arguments }
        let candidate = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.lastPathComponent == "dogfood-candidate",
              FileManager.default.fileExists(atPath: candidate.appendingPathComponent("DOGFOOD_MODE.md").path)
        else { throw Failure.scope }
        let key = arguments[3], model = arguments[4]
        let objective: String
        switch key {
        case "logic-004": objective = "受信確認済みの録音は送信待ちから除いて。残る録音の順番と重複はそのまま保って。"
        case "schema-005": objective = "古い録音データにはdurationSecondsがありません。値がない場合やnullも読み込めるようにして。数値がある場合は保存し直してもその値を保ち、不正な文字列は拒否して。"
        default: throw Failure.arguments
        }
        let root = candidate.appendingPathComponent("work/canary-\(key)").resolvingSymlinksInPath()
        guard root.path.hasPrefix(candidate.path + "/work/") else { throw Failure.scope }
        let output = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessCandidate/Dogfood/\(key)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lease = try LocalExecutionLease(file: output.appendingPathComponent("runner.lock"))
        defer { withExtendedLifetime(lease) {} }
        let result = output.appendingPathComponent("result.json")
        guard !FileManager.default.fileExists(atPath: result.path) else { throw Failure.alreadyStarted }
        let contract = try await RepairAcceptanceContract.capture(root: root, paths: ["Package.swift", "Tests/CanaryTests/Acceptance.swift"])
        try JSONEncoder().encode(contract).write(to: output.appendingPathComponent("acceptance-contract.json"), options: .atomic)
        let target = "Sources/Canary/Subject.swift"
        let editor = RecordedProjectFileEditor(directory: output.appendingPathComponent("edits"))
        let recorder = RecordedStructuredProposal(directory: output.appendingPathComponent("proposal"), editor: editor)
        let start = Date()
        try save("started", model: "UNVERIFIED", harness: "UNVERIFIED", to: result, elapsed: 0)
        let proposal: FileChangeProposal
        do {
            proposal = try await recorder.prepare(rootPath: root.path, target: target, objective: objective, model: model) { source in
                let prompt = """
                \(objective)
                Return JSON only: operation=replace_exact, file=\(target), expected_old_text, new_text, max_changed_lines=1.
                Fix one source line. Preserve indentation. No tools, no other files, no full-file rewrite.
                Source:
                \(source)
                """
                return try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                    messages: [.init(role: .user, content: prompt)], maximumOutputTokens: 512, structuredOutput: .structuredEdit))
            }
        } catch {
            try save("proposalRejectedOrUnavailable", model: "FAIL", harness: "PASS_NO_WRITE", to: result, elapsed: Date().timeIntervalSince(start))
            throw error
        }
        let route = KernelRoutingPolicy.decide(work: .deterministic, localCompatible: false,
            subscriptionDispatchVerified: false, solAvailable: false, astraAvailable: false)
        guard route.route == .tools else { throw Failure.scope }
        do { try GeneratedCodeExecutionGate.requireRuntimeIsolation() }
        catch {
            try save("awaitingRuntimeIsolation", model: "UNVERIFIED", harness: "FAIL", to: result, elapsed: Date().timeIntervalSince(start))
            throw error
        }
        try save("applying", model: "UNVERIFIED", harness: "UNVERIFIED", to: result, elapsed: Date().timeIntervalSince(start))
        try await editor.apply(rootPath: root.path, proposal: proposal)
        do {
            try await ProjectTaskVerification.run(root: root, output: output, contract: contract)
        } catch {
            try await editor.revert(rootPath: root.path, proposal: proposal)
            try save("verificationFailedAndReverted", model: "FAIL", harness: "PASS_ROLLBACK", to: result, elapsed: Date().timeIntervalSince(start))
            throw error
        }
        try save("verified", model: "PASS", harness: "PASS", to: result, elapsed: Date().timeIntervalSince(start))
        print("D1 \(key): Model PASS / Harness PASS; evidence: \(output.path)")
    }

    private static func save(_ phase: String, model: String, harness: String, to file: URL, elapsed: Double) throws {
        let record: [String: Any] = ["phase": phase, "modelResult": model, "harnessResult": harness,
            "elapsedSeconds": elapsed, "fallbackUsed": false, "humanInterventionsDuringRun": 0]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}
