import Foundation
import HarnessCore
import HarnessExecution

/// Examiner check after the tests pass (plan 0005, false-success kind A "a stated condition implemented wrong").
/// An independent call writes scenario tests from the request, the package BEFORE the change (full source: existing rules,
/// constants, comments) and the declarations after it — never the new implementation. They run on a copy of the final code;
/// test functions that do not compile are dropped. Each failing expectation is recomputed by a second call that does not see
/// the expected value (request + code before + the test with its expected values hidden); only failures whose recomputed
/// value equals the test's expectation ("code_wrong") are shown to the builder for one fix,
/// which may decline. The fix is kept only if it builds and the package's tests still pass, else the tested state stands.
/// Offline (2026-10-07): 5 false alarms → no result got worse; 7 detected false successes → 5 became correct.
/// Exception to "protected tests never reach the model" (user decision 2026-10-07): only this examiner reads the visible
/// acceptance tests, as API examples, after the builder already passed them; the builder's prompts still never contain them.
enum BatchExaminerStage {
    /// Steps 1-3 (examiner, its run on a copy, second opinions) never decide the task: if any fails, the tested state stands.
    static func followUp(candidate: URL, root: URL, directory: URL, model: String, objective: String,
                         originals: [String: String], visibleTests: [String: String], permitted: [String], protected: Set<String>,
                         maxEdits: Int, maxLines: Int, editor: RecordedProjectFileEditor, isolated: IsolatedPackageExecution,
                         evidence: URL, budget: inout RequirementCoverage.Budget, record: BatchRunRecord) async throws -> [FileChangeProposal] {
        let finding: Finding
        do {
            guard let found = try await examine(candidate: candidate, root: root, directory: directory, model: model,
                objective: objective, originals: originals, visibleTests: visibleTests, permitted: permitted,
                allowed: budget.allows(.examinerRepair), record: record) else { return [] }
            finding = found
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            record["examinerCheck"] = ["outcome": "examinerUnavailable (\(error))"]; try record.save(); return []
        }
        return try await repair(finding, root: root, directory: directory, model: model, objective: objective,
            permitted: permitted, protected: protected, maxEdits: maxEdits, maxLines: maxLines, editor: editor,
            isolated: isolated, evidence: evidence, budget: &budget, record: record)
    }

    struct Finding {
        let feedback: String; let confirmed: [String]; let verdicts: [String: String]; let examples: [String]
        let tests: String; let target: String; let visibleTests: [String: String]; let candidate: URL
    }

    /// Runs the examiner file on a throwaway copy of `root` (OS sandbox); returns the test output.
    static func runExam(_ tests: String, candidate: URL, root: URL, target: String, visibleTests: [String: String],
                        evidence: URL, openHelpers: Bool = true,
                        fileName: String = "ExaminerScenarioTests.swift") async throws -> String {
        let exam = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-exam")
        defer { try? FileManager.default.removeItem(at: exam) }
        try SecondCandidate.copy(root, to: exam)
        // Examiner tests imitate the visible tests' private helpers (c2-17 `loc`, c2-18 `bigClaim`, b5-15 `d`): open them
        // in this throwaway copy only, so the commonest compile failure cannot void the examination.
        for path in visibleTests.keys where openHelpers {
            let url = exam.appendingPathComponent(path)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                try openingPrivateHelpers(text, except: topLevelNames(tests)).write(to: url, atomically: true, encoding: .utf8)
            }
        }
        try tests.write(to: exam.appendingPathComponent("Tests/\(target)/\(fileName)"), atomically: true, encoding: .utf8)
        let run = IsolatedPackageExecution(candidate: candidate, root: exam.resolvingSymlinksInPath(),
                                           taskID: exam.lastPathComponent + "-" + evidence.lastPathComponent,
                                           protectedPaths: visibleTests.keys.sorted())
        do { return try await run.execute(.test, evidence: evidence).output } catch { return SecondCandidate.latestReceiptOutput(evidence) }
    }

    /// The developer's own examples from the last accepted coverage plan (backlog #40, 2026-10-11), as cases to test.
    static func planExamples(_ record: BatchRunRecord) -> String {
        let plan = ((record["coveragePlans"] as? [[String: Any]])?.last?["plan"] as? [String: Any])?["requirements"] as? [[String: Any]]
        let examples = (plan ?? []).compactMap { ($0["example"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !examples.isEmpty else { return "" }
        return "\n\nThe developer planned with these examples (from the request; they may be wrong). Include a test for each one "
            + "whose expected value you get from the request itself, not from the example:\n"
            + examples.map { "- " + $0 }.joined(separator: "\n")
    }

    static func examine(candidate: URL, root: URL, directory: URL, model: String, objective: String,
                        originals: [String: String], visibleTests: [String: String], permitted: [String], allowed: Bool,
                        record: BatchRunRecord) async throws -> Finding? {
        guard allowed, let testPath = visibleTests.keys.sorted().first else { return nil }
        let target = String(testPath.split(separator: "/")[1])
        let module = target.hasSuffix("Tests") ? String(target.dropLast(5)) : target
        var final: [String: String] = [:]
        for path in permitted where path.hasPrefix("Sources/") {
            final[path] = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        // The package before the change as the plan stage's exact file-map lines: SharedContextMessages turns them into the
        // same system message, so Backburner restores the plan stage's saved preamble instead of re-reading the package.
        let map = String(decoding: try JSONSerialization.data(withJSONObject: originals, options: [.sortedKeys]), as: UTF8.self)
        let before = "The production code BEFORE the change is the EDITABLE file map in the system message (complete; the "
            + "request may change parts of it; nothing is edited in this step).\nEDITABLE: \(map)\nREAD-ONLY: {}"
        func note(_ values: [String: Any]) throws { record["examinerCheck"] = values; try record.save() }

        // 1. Examiner tests. First in the compact format (2026-10-10, backlog #33): the examiner writes only calls and expected
        // values or rules, and the harness writes the Swift. Measured on 112 runs with the blind recheck: alarms 8 of 8 right
        // (the Swift format: 10 of 12), every run with a verdict once diagnostics were one line each. When the compact format
        // gives no runnable test, the examiner writes Swift as before.
        let context = """
        You are an independent examiner. A developer changed a Swift package to satisfy this request:
        \(objective)

        \(before)

        You cannot see the new implementation. Declarations of the production code after the change:
        \(final.sorted { $0.key < $1.key }.map { "// \($0.key)\n" + SecondCandidate.signatures($0.value) }.joined(separator: "\n"))

        Existing tests (they already pass; use them to see how the API is called):
        \(visibleTests.sorted { $0.key < $1.key }.map { "// \($0.key)\n\($0.value)" }.joined(separator: "\n"))

        Write 5-8 tests that check what the existing tests do not. Include at least one test for EACH of: (a) the boundaries \
        of every rule the request relies on, including rules defined only in the code's comments or constants (the first and \
        last value inside a range and the first value outside it); (b) input the request or the existing code treats as invalid \
        or empty (expect the error or empty result the code already uses for such input); (c) existing behaviour the request \
        does not change, using a case right next to the change; (d) every place or output the request names. Use only the \
        declared API. You may call the helpers and fixtures of the existing tests directly (they are available to your tests); \
        do not copy or redefine them. Swift String has no integer subscript (use Array(s) or prefix/dropFirst).
        """
        let compactPrompt = context + planExamples(record) + "\n\n" + compactFormat
        let swiftPrompt = context + planExamples(record) + "\n\nWrite them as ONE new Swift Testing file (import Testing, @testable import \(module), "
            + "@Test func ... with #expect). Give test functions new unique names. Return the Swift source only, in one ```swift block."

        // 2. Run on a copy of the final code; drop test functions that do not compile (one slip must not void the rest).
        var tests = "", kinds: [String: String] = [:], propertyRules: [String: String] = [:], output = ""
        var pruned: [String] = [], format = "compact"
        func runPruning(_ label: String) async throws {
            for round in 0..<3 {
                output = try await runExam(tests, candidate: candidate, root: root, target: target, visibleTests: visibleTests,
                                           evidence: directory.appendingPathComponent("examiner-\(label)-\(round)"))
                let bad = Set(SecondCandidate.matches(#"ExaminerScenarioTests\.swift:(\d+):\d+: error:"#, in: output).compactMap(Int.init))
                guard !bad.isEmpty else { break }
                let (kept, removed) = prune(tests, errorLines: bad)
                guard !removed.isEmpty else { break }
                tests = kept; pruned += removed
            }
        }
        let compactResponse = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
            messages: SharedContextMessages.messages(for: compactPrompt), maximumOutputTokens: 2048))
        (tests, kinds, propertyRules) = compactTests(compactResponse, module: module)
        if !kinds.isEmpty { try await runPruning("compact") }
        // Backlog #38 (2026-10-10, after swarm-orchestrator's "a passing check must be shown able to fail"): a test of what
        // the request changes (aspects a and d) that also passes on the code BEFORE the change does not check the change.
        // Such tests are replaced once by tests the old code would fail.
        var weak: [String] = []
        if !kinds.isEmpty {
            let aspects = compactAspects(compactResponse)
            let passing = Set(SecondCandidate.matches(#"✔ Test (examiner_\w+)\(\) passed"#, in: output))
            let candidates = passing.filter { ["a", "d"].contains(aspects[$0] ?? "") }.sorted()
            if !candidates.isEmpty, let before = try? ExampleCheckStage.beforeCopy(of: root, originals: originals) {
                defer { try? FileManager.default.removeItem(at: before) }
                let subset = "import Foundation\nimport Testing\n@testable import \(module)\n\n"
                    + candidates.map { testBody($0, in: tests) }.joined(separator: "\n\n") + "\n"
                let old = try await runExam(subset, candidate: candidate, root: before.resolvingSymlinksInPath(), target: target,
                                            visibleTests: visibleTests, evidence: directory.appendingPathComponent("examiner-before"))
                weak = Set(SecondCandidate.matches(#"✔ Test (examiner_\w+)\(\) passed"#, in: old)).intersection(candidates).sorted()
            }
            if !weak.isEmpty {
                let ask = compactPrompt + "\n\nThese tests pass on the code BEFORE the change too, so they do not check what the "
                    + "request changes:\n" + weak.map { testBody($0, in: tests) }.joined(separator: "\n\n")
                    + "\n\nWrite replacement tests in the same format, for cases where the code before the change gives a different "
                    + "result than the request requires. Use new test names."
                let more = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                    messages: SharedContextMessages.messages(for: ask), maximumOutputTokens: 1500))
                let (extra, extraKinds, extraRules) = compactTests(more, module: module)
                let fresh = extraKinds.filter { kinds[$0.key] == nil }
                if !fresh.isEmpty {
                    let bodies = fresh.keys.sorted().map { testBody($0, in: extra) }
                    tests += "\n" + bodies.joined(separator: "\n\n") + "\n"
                    kinds.merge(fresh) { first, _ in first }
                    propertyRules.merge(extraRules.filter { fresh[$0.key] != nil }) { first, _ in first }
                    try await runPruning("compact-replaced")
                }
            }
        }
        if Set(SecondCandidate.matches(#"[✔✘] Test (examiner_\w+)\(\)"#, in: output)).isEmpty {
            // Plain code, not a JSON string: long Swift escaped inside JSON broke or hit the limit (c2-09, c2-18
            // "Unterminated string"); fence lines are dropped wherever they are (the closing fence is often missing).
            format = "swift"; kinds = [:]
            let response = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                messages: SharedContextMessages.messages(for: swiftPrompt), maximumOutputTokens: 4096))
            let raw = response.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
                .joined(separator: "\n")
            guard raw.contains("@Test") else {
                try? response.write(to: directory.appendingPathComponent("examiner-response.txt"), atomically: true, encoding: .utf8)
                try note(["outcome": "noExaminerTests", "responseBytes": response.utf8.count]); return nil
            }
            tests = prefixingTestFunctions(raw)
            try await runPruning("swift")
        }
        // Kept for audit (2026-10-10: two alarms on C2 could not be checked by hand because the tests were not saved).
        try? tests.write(to: directory.appendingPathComponent("examiner-tests.swift"), atomically: true, encoding: .utf8)
        try? output.write(to: directory.appendingPathComponent("examiner-output.txt"), atomically: true, encoding: .utf8)
        let failing = Set(SecondCandidate.matches(#"✘ Test (examiner_\w+)\(\) (?:failed|recorded)"#, in: output)).sorted()
        // A rule (property) that fails is shown as something to look at, never as an alarm: on 112 runs 5 of 9 were right.
        let properties = failing.filter { kinds[$0] == "property" }.map { name in
            propertyRules[name] ?? name
        }
        let failed = failing.filter { kinds[$0] != "property" }
        guard !failed.isEmpty else {
            try note(["outcome": "examinerPassed", "pruned": pruned, "format": format, "properties": properties, "weak": weak]); return nil
        }

        // 3. Blind recomputation (2026-10-09). The old second opinion saw the test's expected value and the new code's value
        // and agreed with the test almost always (27B confirmed 39 failures; qwen3.6 agreed with 36), including tests that
        // were simply wrong (c1-02 wrong separator, b5-08 miscounted quotes). Now each failed `#expect(a == b)` is shown with
        // every expected value hidden, and the model computes `a` from the request and the code before the change. Alarm only
        // when its value equals the test's expectation and differs from what the new code returned. Measured on 112 runs
        // (83 fixed + 29 fresh): alarms 9 of 10 right (27B with the old second opinion: 17 of 30), 1 genuine run in 82 flagged.
        var confirmed: [String] = [], verdicts: [String: String] = [:], examples: [String] = []
        var asked = 0, blind: [[String: String]] = []
        for name in failed {
            let body = testBody(name, in: tests)
            let masked = maskingExpectations(body)
            var verdict = "unclear"
            for failure in expectationFailures(of: name, in: output) where asked < 4 {
                asked += 1
                let check = """
                A developer was asked to change a Swift package:
                \(objective)

                \(before)

                Existing tests (fixtures and helpers used below are defined here):
                \(visibleTests.sorted { $0.key < $1.key }.map { "// \($0.key)\n\($0.value)" }.joined(separator: "\n"))

                A test (its expected values are hidden):
                \(masked)

                If the request is implemented correctly, what does this Swift expression return in that test?
                \(failure.expression)

                First, under the heading RULES, quote word for word every comment, constant and condition in the code before \
                the change that affects this value (including the ones that look unrelated to the request, such as grace periods, \
                rounding and what counts toward a limit). Mark each one KEPT or CHANGED BY THE REQUEST; a rule is changed only \
                when the request says so. Then work it out step by step from the request and the code before the change, using \
                every KEPT rule (change only what the request asks). Then end with three lines:
                CASE: <in Japanese, one short sentence without code: the situation this test sets up, in the words of the request>
                WHAT: <in Japanese, a few words without code: what this value is, e.g. 各人の源泉徴収額>
                VALUE: <the value as a Swift literal, or throws if it throws an error>
                """
                // Quoting the rules first (#45, 2026-10-12): the wrong alarms that were not arithmetic slips came from a rule the
                // working left out (c2-01: the grace period counts toward the blocks). On 31 past rechecks, with the calculator:
                // right alarms 15 of 17 kept, wrong alarms 3 → 0. The quotes make the working longer, hence 3000 tokens.
                var answer = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                    messages: SharedContextMessages.messages(for: check), maximumOutputTokens: 3000))
                if SecondCandidate.matches(#"(?m)VALUE:\s*`?(.+?)`?\s*$"#, in: answer).isEmpty {
                    // The working ran out of tokens before the last line (c2-01, c2-05, c2-14 offline): ask for it.
                    answer += "\n" + (try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                        messages: SharedContextMessages.messages(for: check + "\n\nYour working so far:\n" + String(answer.suffix(3000))
                            + "\n\nNow give only the final line `VALUE: <the value as a Swift literal>`."), maximumOutputTokens: 200)))
                }
                var value = SecondCandidate.matches(#"(?m)VALUE:\s*`?(.+?)`?\s*$"#, in: answer).last ?? ""
                var result = blindVerdict(value: value, expected: failure.expected, actual: failure.actual)
                // An alarm resting on a slip in hand arithmetic is worked out again with the calculator's results (#44).
                let slips = result == "code_wrong" ? ArithmeticCheck.wrongSteps(in: answer) : []
                if !slips.isEmpty {
                    let redo = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                        messages: SharedContextMessages.messages(for: check + "\n\nYour working:\n" + String(answer.suffix(4000))
                            + "\n\nA calculator checked your arithmetic. These steps were wrong; the right results are: "
                            + slips.joined(separator: "; ") + ". Redo the working with them and end with the same three lines."),
                        maximumOutputTokens: 2000))
                    if let redone = SecondCandidate.matches(#"(?m)VALUE:\s*`?(.+?)`?\s*$"#, in: redo).last {
                        answer = redo; value = redone
                        result = blindVerdict(value: value, expected: failure.expected, actual: failure.actual)
                    }
                }
                // Kept for diagnosis: on C2 (2026-10-09) every in-pipeline recheck came back "unclear".
                blind.append(["test": name, "expression": failure.expression, "expected": failure.expected,
                              "actual": failure.actual, "value": value, "tail": String(answer.suffix(300))]
                             .merging(slips.isEmpty ? [:] : ["arithmetic": slips.joined(separator: "; ")]) { $1 })
                if result == "code_wrong" {
                    verdict = result
                    examples.append(plainExample(answer: answer, failure: failure))
                } else if verdict == "unclear" { verdict = result }
            }
            verdicts[name] = verdict
            if verdict == "code_wrong" { confirmed.append(name) }
            if expectationFailures(of: name, in: output).isEmpty { blind.append(["test": name, "parsed": "no failed expectation"]) }
        }
        guard !confirmed.isEmpty else {
            try note(["outcome": "failuresNotConfirmed", "verdicts": verdicts, "pruned": pruned, "blind": blind,
                      "format": format, "properties": properties, "weak": weak]); return nil
        }
        try note(["outcome": "confirmed", "confirmed": confirmed, "verdicts": verdicts, "examples": examples, "blind": blind,
                  "format": format, "properties": properties, "weak": weak])

        let feedback = "Your change passed the existing tests, but an independent reviewer's test for the request fails:\n"
            + confirmed.map { testBody($0, in: tests) }.joined(separator: "\n\n")
            + "\n\nWhat your code returned:\n" + confirmed.map { failureDetail($0, in: output) }.joined(separator: "\n")
            + "\n\nIf the request asks for what this test expects, fix the code. If the test expects something the request does "
            + "not ask for or miscalculates, return {\"edits\":[]}."
        return Finding(feedback: feedback, confirmed: confirmed, verdicts: verdicts, examples: examples, tests: tests,
                       target: target, visibleTests: visibleTests, candidate: candidate)
    }
}
