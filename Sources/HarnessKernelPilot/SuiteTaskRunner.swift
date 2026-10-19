import Darwin
import Foundation
import HarnessCore
import HarnessExecution
import TaskOrchestrator

/// `--suite-task <candidate> <task.json> <model> <outputRoot>`: one measured run of one frozen suite task.
/// Reads only the parts of the task the builder may see (objective, initial files, protected tests, limits);
/// the reference solution is never read. Holdout tests are added only after the run, to an isolated copy of the
/// final state, to detect false success. Writes `<outputRoot>/<id>-<stamp>/kpi.json` and prints it.
enum SuiteTaskRunner {
    struct SuiteTask: Decodable {
        let id: String
        let objective: String
        let initialFiles: [String: String]
        let protectedTests: [String]
        let maxEdits: Int
        let maxLines: Int
        let holdoutTests: [String: String]
    }
    enum Failure: Error { case arguments, scope }

    /// Fixed conversion of the suite's change limit to the harness edit budget (pre-registered before B.6 v1, never tuned
    /// per task). The suite counts changed diff lines; StructuredEditBatch counts the full old block plus the full new
    /// block of every replace_exact edit. A region with d changed lines anchored by k context lines on each side costs
    /// at most 2d + 4k, so with k = 3 (the usual diff context): 2 * maxLines + 12 * maxEdits.
    static func harnessMaxLines(suiteMaxLines: Int, maxEdits: Int) -> Int { 2 * suiteMaxLines + 12 * maxEdits }

    static func run(_ arguments: [String]) async throws {
        let options = Dictionary(arguments.dropFirst(6).compactMap { arg -> (String, String)? in
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init); return parts.count == 2 ? (parts[0], parts[1]) : nil },
            uniquingKeysWith: { _, last in last })
        guard arguments.count >= 6, options.count == arguments.count - 6,
              Set(options.keys).isSubset(of: ["scope", "proposalTokens", "secondary", "examiner", "examples", "gated", "clarify"]),
              options["clarify"].map({ ["self", "oracle"].contains($0) }) ?? true,
              ["examiner", "examples", "gated"].allSatisfy({ options[$0].map { ["on", "off"].contains($0) } ?? true }),
              options["scope"].map({ ["package", "selector"].contains($0) }) ?? true,
              options["proposalTokens"].map({ Int($0) != nil }) ?? true else { throw Failure.arguments }
        let packageScope = (options["scope"] ?? "package") == "package"
        let candidate = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        let task = try JSONDecoder().decode(SuiteTask.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
        let model = arguments[4]
        guard task.id.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else { throw Failure.scope }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "").lowercased()
        let key = "b5r-\(task.id)-\(stamp)"
        let root = candidate.appendingPathComponent("work/\(key)")
        let output = URL(fileURLWithPath: arguments[5]).appendingPathComponent("\(task.id)-\(stamp)")
        try write(task.initialFiles, to: root)
        // Candidate 3: points settled before building. Only `clarify=oracle` reads the reference, and only to let the
        // stand-in user answer the builder's questions; the builder itself never sees it.
        var objective = task.objective, clarified: [ClarifyStage.Point] = [], clarifyError: String?
        let clarifyStart = Date()
        if let mode = options["clarify"] {
            struct Reference: Decodable { let reference: [String: String]; let rationale: String }
            var reference: [String: String] = [:]
            if mode == "oracle" {
                let intended = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
                reference = intended.reference
                reference["(作者のメモ)"] = intended.rationale
            }
            do {
                clarified = try await ClarifyStage.clarify(objective: task.objective, files: task.initialFiles,
                    protected: task.protectedTests, model: model, mode: mode, reference: reference)
            } catch { clarifyError = String(describing: error) }
            objective = ClarifyQuestions.objective(task.objective, with: clarified)
        }
        let clarifySeconds = Date().timeIntervalSince(clarifyStart)
        let budget = harnessMaxLines(suiteMaxLines: task.maxLines, maxEdits: task.maxEdits)
        let manifest: [String: Any] = ["objective": objective, "protectedFiles": task.protectedTests,
                                       "appendOnly": [String](), "maxEdits": task.maxEdits, "maxLines": budget,
                                       "scopeMode": packageScope ? "package" : "selector",
                                       "proposalOutputTokens": Int(options["proposalTokens"] ?? "2048") ?? 2048,
                                       "examinerCheck": options["examiner"] == "on", "exampleCheck": options["examples"] == "on",
                                       "gatedChecks": options["gated"] == "on"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("task.json"), options: .atomic)

        let start = Date()
        var kpi: [String: Any] = ["id": task.id, "model": model, "startedAt": ISO8601DateFormatter().string(from: start),
                                  "root": root.path, "output": output.path,
                                  "suiteMaxLines": task.maxLines, "harnessMaxLines": budget, "maxEdits": task.maxEdits,
                                  "clarify": options["clarify"] ?? "off", "clarifySeconds": clarifySeconds, "clarifyError": clarifyError ?? "", "clarifyRaw": ClarifyStage.lastRaw,
                                  "clarified": clarified.map { ["q": $0.question, "a": $0.answer] }]
        var selectedRoot = root, selectedOutput = output
        do {
            if let secondary = options["secondary"] {
                // Gated fallback: a second candidate only when the primary does not pass its tests (SecondCandidate).
                let outcome = try await SecondCandidate.run(candidate: candidate, root: root.resolvingSymlinksInPath(), key: key,
                    primary: model, secondary: secondary, examiner: model, output: output)
                selectedRoot = outcome.root; selectedOutput = outcome.output
                kpi["secondCandidate"] = ["model": secondary, "selected": outcome.selected,
                                          "examinerPassed": outcome.examinerPassed, "examinerFailed": outcome.examinerFailed]
            } else {
                try await TaskOrchestrator.runTask(candidate: candidate, root: root.resolvingSymlinksInPath(), key: key,
                                                   model: model, output: output)
            }
        } catch { kpi["runError"] = String(describing: error) }
        kpi["seconds"] = Date().timeIntervalSince(start)
        kpi["modelUsage"] = InferenceEnvironment.shared.usage
        let record = (try? JSONSerialization.jsonObject(with: Data(contentsOf: selectedOutput.appendingPathComponent("result.json")))) as? [String: Any] ?? [:]
        for field in ["phase", "harnessResult", "testsPassedHarnessResult", "modelFirstPass", "modelCompilerRepair",
                      "modelRequirementReplan", "modelRuntimeRepair", "failureClass", "recoveryActions", "rollbackResult",
                      "permittedFiles", "environmentClassification", "scopeSource", "scopeModeFallback"] {
            kpi[field] = record[field]
        }
        let testsPassed = record["phase"] as? String == "testsPassedRequirementVerificationPending"
        kpi["testsPassed"] = testsPassed
        if testsPassed {
            let holdout = candidate.appendingPathComponent("work/\(key)-holdout")
            try copyProject(selectedRoot, to: holdout)
            try write(task.holdoutTests, to: holdout)
            let check = try await SuiteCommand.buildAndTest(candidate: candidate, root: holdout.resolvingSymlinksInPath(),
                                                           evidence: output.appendingPathComponent("holdout"))
            let passed = ((check["test"] as? [String: Any])?["exit"] as? Int) == 0
            kpi["holdout"] = passed ? "PASS" : "FAIL"
            kpi["holdoutOutput"] = ((check["test"] as? [String: Any])?["output"] as? String).map { String($0.suffix(2_000)) }
            removeScratch(holdout)
        } else { kpi["holdout"] = "NOT_RUN" }
        // Proxy success (B.6): tests passed in the run AND the hidden holdout passed. The completion contract still
        // needs the external requirement verification; this proxy never finalizes anything.
        kpi["proxySuccess"] = testsPassed && kpi["holdout"] as? String == "PASS"
        kpi["falseSuccess"] = testsPassed && kpi["holdout"] as? String == "FAIL"
        kpi["memory"] = memory()
        removeScratch(root); removeScratch(selectedRoot)
        let data = try JSONSerialization.data(withJSONObject: kpi, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("kpi.json"), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }

    static func write(_ files: [String: String], to root: URL) throws {
        for (path, content) in files {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.isEmpty else { throw Failure.scope }
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Final source state without build scratch or lock files.
    static func copyProject(_ root: URL, to target: URL) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { throw Failure.scope }
        for case let url as URL in walker {
            if url.lastPathComponent.hasPrefix(".harness-execution") { walker.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1))
            let destination = target.appendingPathComponent(relative)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: destination)
        }
    }

    /// Build scratch is large (GBs over a suite); sources, task.json and evidence stay.
    static func removeScratch(_ root: URL) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".harness-execution"))
    }

    /// Peak resident memory of this process, and the current / lifetime-max footprint of the local model runtime
    /// (`ollama` server and its `llama-server` model process).
    static func memory() -> [String: Any] {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var result: [String: Any] = ["harnessMaxRSSBytes": Int(usage.ru_maxrss)]
        var pids = [pid_t](repeating: 0, count: 4_096)
        let bytes = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var ollama: [[String: Any]] = []
        for pid in pids.prefix(max(0, Int(bytes))) where pid > 0 {
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, UInt32(name.count)) > 0,
                  ["ollama", "llama-server"].contains(where: String(cString: name).lowercased().contains) else { continue }
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { continue }
            ollama.append(["pid": Int(pid), "name": String(cString: name), "physFootprintBytes": Int(info.ri_phys_footprint),
                           "lifetimeMaxPhysFootprintBytes": Int(info.ri_lifetime_max_phys_footprint)])
        }
        result["ollama"] = ollama
        return result
    }
}
