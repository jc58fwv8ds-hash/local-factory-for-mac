import CryptoKit
import Foundation
import HarnessExecution

/// `--verifier-phase4-case <case.json> <claims.json|none> <phase1.json|none> <out.json>` (Phase 4: adds Arm E; Arm D unchanged).
/// Replays a case's writes and test runs through the real isolated Build/Test path, keeps the
/// Harness-owned receipt authority in this process, then evaluates Arms B, C (frozen code, fed
/// with evidence derived from these real runs) and D. Never calls a model.
enum VerifierPhase4Command {
    struct Step: Codable { let kind: String; let files: [String: String]? }
    struct Case: Codable {
        let taskID: String
        let clauses: [RequirementVerification.Item]
        let requirements: [RequirementVerification.Item]
        let initialFiles: [String: String]
        let protectedTests: [String]
        let requiredTests: [String: [String]]
        let regressionTests: [String]?
        let steps: [Step]
    }

    static func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Per-test outcomes from Swift Testing / XCTest console output. Unknown lines are ignored;
    /// a test with no recognizable line simply has no result.
    static func results(_ output: String) -> [String: String] {
        var map: [String: String] = [:]
        let patterns = [#"Test (\S+\(\S*\)) (passed|failed|skipped)"#, #"Test (\S+\(\S*\)) recorded an (issue)"#,
                        #"Test Case '-\[\S+ (\S+)\]' (passed|failed|skipped)"#]
        for line in output.components(separatedBy: "\n") {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let name = Range(m.range(at: 1), in: line), let status = Range(m.range(at: 2), in: line) else { continue }
                let id = String(line[name]), value = String(line[status]) == "issue" ? "failed" : String(line[status])
                if map[id] != "failed" { map[id] = value }   // any failure wins
            }
        }
        return map
    }

    static func run(_ arguments: [String]) async throws {
        guard arguments.count == 6 else { throw CocoaError(.fileReadInvalidFileName) }
        let spec = try JSONDecoder().decode(Case.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let claims = arguments[3] == "none" ? nil
            : try JSONDecoder().decode([VerifierAdmission.Claim].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
        let phase1 = arguments[4] == "none" ? nil
            : try JSONDecoder().decode(VerifierAdmission.Outcome.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[4]))).items
        // The candidate is the package whose .build/debug holds this executable (the isolation
        // supervisor helper is resolved from the same place).
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().standardizedFileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        var candidate = executable.deletingLastPathComponent()
        while candidate.path != "/" && (candidate.path.contains("/.build") || !FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path)) {
            candidate = candidate.deletingLastPathComponent()
        }
        guard candidate.path != "/" else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        let base = candidate.appendingPathComponent("work/p4-runs/\(spec.taskID)-\(UUID().uuidString)")
        let root = base.appendingPathComponent("fixture"), evidence = base.appendingPathComponent("evidence")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Resolve only existing directories so the URL form never changes between runs.
        try fm.createDirectory(at: evidence, withIntermediateDirectories: true)
        let resolvedRoot = root.resolvingSymlinksInPath(), resolvedEvidence = evidence.resolvingSymlinksInPath()
        var paths = Set(spec.initialFiles.keys)
        func write(_ files: [String: String]) throws {
            for (path, content) in files {
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw CocoaError(.fileWriteInvalidFileName) }
                let url = resolvedRoot.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
                paths.insert(path)
            }
        }
        func current() throws -> [String: String] {
            Dictionary(uniqueKeysWithValues: try paths.sorted().map { ($0, try String(contentsOf: resolvedRoot.appendingPathComponent($0), encoding: .utf8)) })
        }
        try write(spec.initialFiles)
        let contract = Dictionary(uniqueKeysWithValues: spec.protectedTests.map { ($0, sha(spec.initialFiles[$0] ?? "")) })
        let adapter = IsolatedPackageExecution(candidate: candidate, root: resolvedRoot, taskID: spec.taskID, protectedPaths: spec.protectedTests)
        let issuer = VerifierExecutionReceipts(adapter: adapter, evidence: resolvedEvidence)
        let required = Set(spec.requiredTests.values.flatMap { $0 } + (spec.regressionTests ?? []))
        var events: [[String: Any]] = [], runs: [[String: Any]] = [], seq = 0
        var lastReceipt: VerifierExecutionReceipts.Receipt? = nil
        for step in spec.steps {
            seq += 1
            if step.kind == "write", let files = step.files {
                await issuer.invalidateForInputWrite()
                try write(files)
                for (path, content) in files.sorted(by: { $0.key < $1.key }) {
                    events.append(["seq": seq, "kind": "write", "path": path, "sha256": sha(content)]); seq += 1
                }
                continue
            }
            guard step.kind == "test" else { continue }
            let started = Date()
            let before = Set((try? fm.contentsOfDirectory(atPath: resolvedEvidence.path)) ?? [])
            var run: [String: Any] = ["seq": seq]
            do { lastReceipt = try await issuer.execute(requiredTests: required); run["receipt"] = lastReceipt!.id.uuidString }
            catch { run["error"] = String(describing: error) }
            run["seconds"] = Date().timeIntervalSince(started)
            // Per-test outcomes come from the Harness's own execution record of this run.
            let records = ((try? fm.contentsOfDirectory(atPath: resolvedEvidence.path)) ?? []).filter { !before.contains($0) && $0.hasPrefix("test-") && !$0.contains("adjudicated") }
            var output = "", exit = 1
            if let record = records.sorted().last,
               let data = try? Data(contentsOf: resolvedEvidence.appendingPathComponent(record)),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                output = object["output"] as? String ?? ""; exit = object["exitStatus"] as? Int ?? 1
            }
            let parsed = results(output)
            run["results"] = parsed; run["exitStatus"] = exit
            runs.append(run)
            events.append(["seq": seq, "kind": "test", "command": "swift test (Harness isolated)", "exitCode": exit,
                           "fileHashes": try current().mapValues(sha),
                           "results": parsed.sorted { $0.key < $1.key }.map { ["id": $0.key, "status": $0.value] }])
        }
        let finalCode = try current()
        let finalHashes = finalCode.mapValues(sha)
        var receiptValid = false, notes: [String] = []
        if let receipt = lastReceipt {
            do { try await issuer.validate(receipt, requiredTests: required); receiptValid = true }
            catch { notes.append("receipt rejected: \(error)") }
        } else { notes.append("no receipt minted") }
        let protectedIntact = contract.allSatisfy { finalHashes[$0.key] == $0.value }
        let freshRun = events.last { ($0["kind"] as? String) == "test" && ($0["fileHashes"] as? [String: String]) == finalHashes }
        var fresh: [String: String] = [:]
        for result in (freshRun?["results"] as? [[String: String]]) ?? [] { fresh[result["id"]!] = result["status"]! }
        let execution = VerifierArmD.Execution(receiptValid: receiptValid, protectedIntact: protectedIntact, freshResults: fresh,
                                               requiredTests: spec.requiredTests, notes: notes)
        // Arms B/C: frozen code, evidence derived from the real runs above.
        let caseObject: [String: Any] = ["taskID": spec.taskID,
            "clauses": spec.clauses.map { ["id": $0.id, "text": $0.text] },
            "requirements": spec.requirements.map { ["id": $0.id, "text": $0.text] },
            "finalCode": finalCode,
            "evidence": ["protectedTests": contract, "requiredTests": spec.requiredTests,
                         "regressionTests": spec.regressionTests ?? [], "events": events, "claimSeq": seq + 1]]
        let bcCase = try JSONDecoder().decode(DeterministicVerifier.Case.self, from: JSONSerialization.data(withJSONObject: caseObject))
        let armD = VerifierArmD.admit(clauses: spec.clauses, requirements: spec.requirements, production: finalCode,
                                      protectedPaths: Set(spec.protectedTests), claims: claims, phase1: phase1, execution: execution)
        let armE = VerifierArmE.admit(clauses: spec.clauses, requirements: spec.requirements, production: finalCode,
                                      protectedPaths: Set(spec.protectedTests), claims: claims, phase1: phase1, execution: execution)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: encoder.encode(value)) }
        let output: [String: Any] = ["B": try json(DeterministicVerifier.armB(bcCase)),
                                     "C": try json(DeterministicVerifier.armC(bcCase, phase1: phase1)),
                                     "D": try json(armD),
                                     "E": try json(armE),
                                     "execution": ["runs": runs, "receiptValid": receiptValid, "protectedIntact": protectedIntact,
                                                   "notes": notes, "finalHashes": finalHashes, "workdir": base.path]]
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: arguments[5]))
        // Build products are large and not evidence; the Harness records under evidence/ are kept.
        try? fm.removeItem(at: resolvedRoot.appendingPathComponent(".harness-execution"))
    }
}
