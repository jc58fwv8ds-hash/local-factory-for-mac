import Foundation
import HarnessCore
import HarnessExecution

/// Gated fallback candidate (plan 0005, opt-in). The primary model runs the task as usual. Only when it does not reach
/// "tests passed", a second model runs the same task on a pristine copy; its result is accepted only if it passes at least
/// `gate` of the examiner's scenario tests (request + ORIGINAL declarations + visible tests; never the implementation). So a
/// second candidate can add a success but cannot add an unexamined false success. Never finalizes anything: the accepted run
/// still ends at the requirement gate (external verification).
package enum SecondCandidate {
    package static let gate = 0.8

    package struct Outcome: Sendable {
        package let selected: String          // "primary" | "secondary" | "none"
        package let root: URL                 // package holding the selected (or primary) final code
        package let output: URL               // run output of the selected (or primary) run
        package let examinerPassed: Int
        package let examinerFailed: Int
    }

    package static func run(candidate: URL, root: URL, key: String, primary: String, secondary: String,
                            examiner: String, output: URL) async throws -> Outcome {
        let fm = FileManager.default
        let pristine = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-second")
        try copy(root, to: pristine)
        let originals = try snapshot(pristine)
        try? await TaskOrchestrator.runTask(candidate: candidate, root: root, key: key, model: primary, output: output)
        func phase(_ out: URL) -> String? {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("result.json")))
                as? [String: Any])?["phase"] as? String
        }
        let pending = "testsPassedRequirementVerificationPending"
        let none = Outcome(selected: "none", root: root, output: output, examinerPassed: 0, examinerFailed: 0)
        if phase(output) == pending {
            try? fm.removeItem(at: pristine)
            return Outcome(selected: "primary", root: root, output: output, examinerPassed: 0, examinerFailed: 0)
        }
        let secondOutput = output.appendingPathComponent("second")
        try? await TaskOrchestrator.runTask(candidate: candidate, root: pristine.resolvingSymlinksInPath(), key: key + "-2",
                                            model: secondary, output: secondOutput)
        guard phase(secondOutput) == pending else { return none }
        let (passed, failed) = try await examine(candidate: candidate, finalRoot: pristine, originals: originals,
                                                 model: examiner, evidence: secondOutput.appendingPathComponent("examiner"))
        let accepted = passed + failed > 0 && Double(passed) / Double(passed + failed) >= gate
        let summary: [String: Any] = ["selected": accepted ? "secondary" : "none", "examinerPassed": passed,
                                      "examinerFailed": failed, "gate": gate, "secondaryModel": secondary]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("second-candidate.json"), options: .atomic)
        return accepted ? Outcome(selected: "secondary", root: pristine, output: secondOutput, examinerPassed: passed, examinerFailed: failed)
            : Outcome(selected: "none", root: root, output: output, examinerPassed: passed, examinerFailed: failed)
    }

    /// One examiner call; its tests run with the final code in a separate copy, in the OS sandbox.
    static func examine(candidate: URL, finalRoot: URL, originals: [String: String], model: String,
                        evidence: URL) async throws -> (passed: Int, failed: Int) {
        guard let task = try JSONSerialization.jsonObject(with: Data(contentsOf: finalRoot.appendingPathComponent("task.json"))) as? [String: Any],
              let objective = task["objective"] as? String else { return (0, 0) }
        let visible = originals.filter { $0.key.split(separator: "/").contains("Tests") }
        guard let testPath = visible.keys.sorted().first else { return (0, 0) }
        let target = testPath.split(separator: "/")[1]
        let module = target.hasSuffix("Tests") ? String(target.dropLast(5)) : String(target)
        let declarations = originals.filter { $0.key.hasPrefix("Sources/") }.sorted { $0.key < $1.key }
            .map { "// \($0.key)\n" + signatures($0.value) }.joined(separator: "\n")
        let prompt = """
        You are an independent examiner. A developer will change a Swift package to satisfy this request:
        \(objective)

        Declarations of the production code BEFORE the change (the request may add or change API):
        \(declarations)

        Existing tests:
        \(visible.sorted { $0.key < $1.key }.map { "// \($0.key)\n\($0.value)" }.joined(separator: "\n"))

        Write ONE Swift Testing file (import Testing, @testable import \(module)) with 4-6 small @Test functions that check what \
        the request asks: every case it names, stated boundaries, behaviour that must stay unchanged, every place the rule applies. \
        Use API names exactly as the request or the declarations give them. Unique function names. Return JSON {"content": "<swift source>"}.
        """
        let response = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
            messages: [.init(role: .user, content: prompt)], maximumOutputTokens: 3000, structuredOutput: .fileContent))
        guard let data = StructuredResponseText.jsonObject(in: response).data(using: .utf8),
              let raw = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["content"] as? String else { return (0, 0) }
        // Examiner test names must not collide with the package's own tests (a redeclaration would void the whole file).
        let tests = BatchExaminerStage.prefixingTestFunctions(raw)
        let exam = finalRoot.deletingLastPathComponent().appendingPathComponent(finalRoot.lastPathComponent + "-exam")
        try copy(finalRoot, to: exam)
        defer { try? FileManager.default.removeItem(at: exam) }
        try tests.write(to: exam.appendingPathComponent("Tests/\(target)/ExaminerScenarioTests.swift"), atomically: true, encoding: .utf8)
        let isolated = IsolatedPackageExecution(candidate: candidate, root: exam.resolvingSymlinksInPath(), taskID: exam.lastPathComponent,
                                                protectedPaths: visible.keys.sorted())
        var text = ""
        do { text = try await isolated.execute(.test, evidence: evidence).output } catch { text = latestReceiptOutput(evidence) }
        let examinerNames = Set(matches(#"func (\w+)\("#, in: tests))
        let passed = Set(matches(#"✔ Test (\w+)\(\) passed"#, in: text)).intersection(examinerNames).count
        let failed = Set(matches(#"✘ Test (\w+)\(\) (?:failed|recorded)"#, in: text)).intersection(examinerNames).count
        return (passed, failed)
    }

    static func signatures(_ source: String) -> String {
        let declaration = #"^\s*(@\w+\s+)*((public|internal|private|fileprivate|static|final|mutating|nonisolated|override)\s+)*(struct|enum|class|actor|protocol|extension|func|init|var|let|case|typealias)\b"#
        return source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { $0.range(of: declaration, options: .regularExpression) != nil && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .map { line in line.components(separatedBy: "{").first.map { $0.trimmingCharacters(in: .whitespaces) + (line.contains("{") ? " {" : "") } ?? line }
            .joined(separator: "\n")
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Every capture group of every match.
    static func matchGroups(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }

    static func latestReceiptOutput(_ evidence: URL) -> String {
        let receipts = ((try? FileManager.default.contentsOfDirectory(at: evidence, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("test-") && !$0.lastPathComponent.contains("adjudicated") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard let last = receipts.last, let record = (try? JSONSerialization.jsonObject(with: Data(contentsOf: last))) as? [String: Any]
        else { return "" }
        return record["output"] as? String ?? ""
    }

    /// Text files of a package without build scratch or locks.
    static func snapshot(_ root: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        let base = root.resolvingSymlinksInPath().path
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) ?? .init() {
            guard url.pathExtension == "swift", !url.path.contains("/.harness-execution") else { continue }
            files[String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))] = try String(contentsOf: url, encoding: .utf8)
        }
        return files
    }

    static func copy(_ root: URL, to target: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: target)
        let base = root.resolvingSymlinksInPath().path
        for case let url as URL in fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) ?? .init() {
            if url.lastPathComponent.hasPrefix(".harness-execution") { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  !url.path.contains("/.harness-execution") else { continue }
            let destination = target.appendingPathComponent(String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1)))
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: destination)
        }
    }
}
