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

    /// 4. Up to two fixes by the builder, which may decline. A fix is kept only if it builds, the package's tests pass and the
    /// confirmed examiner tests now pass (b5-04: an off-target fix passed the package's tests and was kept while the examined
    /// bug remained). After a first fix that leaves them failing, the builder sees the new result once; otherwise every
    /// examiner fix is rolled back and the tested state stands.
    static func repair(_ finding: Finding, root: URL, directory: URL, model: String, objective: String, permitted: [String],
                       protected: Set<String>, maxEdits: Int, maxLines: Int, editor: RecordedProjectFileEditor,
                       isolated: IsolatedPackageExecution, evidence: URL, budget: inout RequirementCoverage.Budget,
                       record: BatchRunRecord) async throws -> [FileChangeProposal] {
        let (confirmed, verdicts, examples) = (finding.confirmed, finding.verdicts, finding.examples)
        func note(_ values: [String: Any]) throws { record["examinerCheck"] = values; try record.save() }
        let files = permitted.filter { $0.hasPrefix("Sources/") && !protected.contains($0) }
        var feedback = finding.feedback, applied: [RecoverableFileBatch] = [], accepted: [FileChangeProposal] = []
        var outcome = ""
        func rollbackAll() async throws { for t in applied.reversed() { _ = try await t.run(root: root, direction: .rollback) } }
        for round in 1...2 {
            let suffix = round == 1 ? "" : "-\(round)"
            // Diagnose before fixing (b5-04: without it the builder twice "fixed" the trailing '-' the request talked about,
            // while the failing result "l-eading-spaces" came from the leading one; with it, one fix passed the holdout).
            let diagnosis: String
            do {
                let current = try files.reduce(into: [String: String]()) { $0[$1] = try String(contentsOf: root.appendingPathComponent($1), encoding: .utf8) }
                let map = String(decoding: try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]), as: UTF8.self)
                let ask = objective + "\n" + feedback.components(separatedBy: "\n\nIf the request asks")[0]
                    .components(separatedBy: "\n\nFind the actual cause")[0]
                    + "\n\nDo not write code yet. Trace the failing input through the current code step by step and name the exact "
                    + "line(s) that produce the wrong value, and why. At most 8 short lines.\nEDITABLE: \(map)"
                diagnosis = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                    messages: SharedContextMessages.messages(for: ask), maximumOutputTokens: 700))
            } catch { diagnosis = "" }
            let fixFeedback = diagnosis.isEmpty ? feedback : feedback + "\n\nDiagnosis of the cause (from tracing the code):\n" + diagnosis
            record.increment("modelProposalCount")
            let proposals: [FileChangeProposal]
            do {
                proposals = try await RecordedBatchProposal(directory: directory.appendingPathComponent("examiner-proposal" + suffix)).prepare(
                    root: root, files: files, objective: objective, model: model, protected: protected, appendOnly: [],
                    maxEdits: maxEdits, maxLines: maxLines, editor: editor) { [fixFeedback] current in
                    let map = String(decoding: try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]), as: UTF8.self)
                    let prompt = """
                    \(objective)
                    \(fixFeedback)
                    Return JSON only: {"edits":[{"operation":"replace_exact","file":"relative path","expected_old_text":"exact source anchor","new_text":"replacement"}]}.
                    Each expected_old_text must occur exactly once in its file. Preserve indentation. No tools.
                    EDITABLE: \(map)
                    """
                    return try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
                        messages: SharedContextMessages.messages(for: prompt), maximumOutputTokens: 2048, structuredOutput: .structuredEditBatch))
                }
            } catch {
                outcome = "builderDeclinedOrUnusable round \(round) (\(error))"; break
            }
            let transaction = RecoverableFileBatch(directory: directory.appendingPathComponent("transaction-examiner" + suffix))
            try await transaction.prepare(root: root, proposals: proposals, allowed: Set(files), protected: protected)
            _ = try await transaction.run(root: root, direction: .resume)
            applied.append(transaction)
            if try await BatchCompilerRepair.compile(isolated, evidence: evidence, root: root) != nil {
                outcome = "rolledBack round \(round) (does not compile)"; break
            }
            guard case .passed = try await BatchCompilerRepair.test(isolated, evidence: evidence) else {
                outcome = "rolledBack round \(round) (tests fail)"; break
            }
            accepted += proposals
            let recheck = try await runExam(finding.tests, candidate: finding.candidate, root: root, target: finding.target,
                visibleTests: finding.visibleTests, evidence: directory.appendingPathComponent("examiner-recheck\(suffix)"))
            let stillFailing = confirmed.filter { name in
                !SecondCandidate.matches(#"✔ Test (examiner_\w+)\(\) passed"#, in: recheck).contains(name)
            }
            if stillFailing.isEmpty {
                _ = budget.consume(.examinerRepair)
                record.append("recoveryActions", "examinerRepair")
                try note(["outcome": "applied round \(round)", "confirmed": confirmed, "verdicts": verdicts, "examples": examples,
                          "files": accepted.map(\.relativePath)])
                return accepted
            }
            outcome = "rolledBack round \(round) (examiner tests still fail: \(stillFailing.joined(separator: ", ")))"
            feedback = "Your previous fix did not make the reviewer's test pass. After it, the test still fails:\n"
                + stillFailing.map { testBody($0, in: finding.tests) + "\n" + failureDetail($0, in: recheck) }.joined(separator: "\n\n")
                + "\n\nFind the actual cause in the code and fix it. If the test expects something the request does not ask for, "
                + "return {\"edits\":[]}."
        }
        try await rollbackAll()
        try note(["outcome": outcome, "confirmed": confirmed, "verdicts": verdicts, "examples": examples])
        return []
    }

    /// Top-level `private` / `fileprivate` declarations of a test file become internal, so another test file can call them —
    /// except names the examiner file declares itself (an internal and a file-private `loc` in one module do not compile).
    static func openingPrivateHelpers(_ text: String, except names: Set<String> = []) -> String {
        text.components(separatedBy: "\n").map { line in
            guard let name = topLevelNames(line).first, !names.contains(name) else { return line }
            return line.replacingOccurrences(of: #"^(private|fileprivate) "#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    /// Names of top-level `func` / `let` / `var` / type declarations (no indentation), with or without an access modifier.
    static func topLevelNames(_ text: String) -> Set<String> {
        Set(SecondCandidate.matches(#"(?m)^(?:(?:private|fileprivate|internal|public) )?(?:(?:static|final) )*(?:func|let|var|struct|enum|class|typealias) (\w+)"#, in: text))
    }

    /// Prefixes `@Test` functions with `examiner_` so they cannot collide with the package's tests. Helper functions keep
    /// their names (renaming every `func` broke their call sites: c2-18 "cannot find 'makeClaim'", all tests dropped).
    static func prefixingTestFunctions(_ source: String) -> String {
        source.replacingOccurrences(of: #"(@Test[^\n]*\n?\s*func )(\w+)\("#, with: "$1examiner_$2(", options: .regularExpression)
    }

    /// Removes every `@Test` function whose body contains one of the 1-based error lines.
    static func prune(_ tests: String, errorLines: Set<Int>) -> (String, [String]) {
        let lines = tests.components(separatedBy: "\n")
        var keep = Array(repeating: true, count: lines.count), removed: [String] = [], i = 0
        while i < lines.count {
            guard lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("@Test") else { i += 1; continue }
            var j = i, depth = 0, opened = false
            while j < lines.count {
                depth += lines[j].filter { $0 == "{" }.count - lines[j].filter { $0 == "}" }.count
                opened = opened || lines[j].contains("{")
                if opened && depth <= 0 { break }
                j += 1
            }
            if errorLines.contains(where: { (i + 1)...(j + 1) ~= $0 }) {
                for k in i..<min(j + 1, lines.count) { keep[k] = false }
                removed.append(SecondCandidate.matches(#"func (\w+)"#, in: lines[i...min(i + 1, lines.count - 1)].joined(separator: " ")).first ?? "line\(i + 1)")
            }
            i = j + 1
        }
        return (zip(lines, keep).filter(\.1).map(\.0).joined(separator: "\n"), removed)
    }

    static func testBody(_ name: String, in tests: String) -> String {
        guard let range = tests.range(of: "func \(name)(") else { return name }
        let start = tests[..<range.lowerBound].range(of: "@Test", options: .backwards)?.lowerBound ?? range.lowerBound
        var depth = 0, opened = false, end = tests.endIndex
        for index in tests[range.lowerBound...].indices {
            if tests[index] == "{" { depth += 1; opened = true }
            if tests[index] == "}" { depth -= 1; if opened && depth == 0 { end = tests.index(after: index); break } }
        }
        return String(tests[start..<end])
    }

    struct ExpectationFailure: Equatable {
        let expression: String; let expected: String; let actual: String
    }

    /// Failed `#expect(a == b)` of one test in the Swift Testing output: the expression `a`, the expected `b` and the value
    /// `a` had ("throws" when it threw).
    static func expectationFailures(of name: String, in output: String) -> [ExpectationFailure] {
        let lines = output.components(separatedBy: "\n")
        var failures: [ExpectationFailure] = []
        for (index, line) in lines.enumerated() where line.contains("Test \(name)()") && line.contains("recorded an issue") {
            guard let match = SecondCandidate.matches(#"Expectation failed: (?:try )?(.+?) == (.+)$"#, in: line).first,
                  let expected = SecondCandidate.matches(#"Expectation failed: (?:try )?.+? == (.+)$"#, in: line).first else { continue }
            let expression = match.trimmingCharacters(in: .whitespaces)
            let block = lines[(index + 1)..<min(lines.count, index + 8)].prefix { !$0.contains("Test examiner_") }
            if block.contains(where: { $0.contains("Caught error") || $0.contains("<not evaluated>") }) {
                failures.append(.init(expression: expression, expected: expected.trimmingCharacters(in: .whitespaces), actual: "throws"))
                continue
            }
            // The ↳ line that evaluates the left side alone, not the whole comparison.
            for detail in block {
                guard let arrow = detail.range(of: " → "), let mark = detail.range(of: "↳") else { continue }
                let key = detail[mark.upperBound..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"^try "#, with: "", options: .regularExpression)
                guard !key.contains(" == "), normalized(key) == normalized(expression) else { continue }
                failures.append(.init(expression: expression, expected: expected.trimmingCharacters(in: .whitespaces),
                                      actual: String(detail[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)))
                break
            }
        }
        return failures
    }

    /// The test with every `#expect(a == b)` turned into `#expect(a == <hidden>)`.
    static func maskingExpectations(_ body: String) -> String {
        body.replacingOccurrences(of: #"(?m)(#expect\((?:try )?.+?) == .+?\)\s*$"#, with: "$1 == <hidden>)", options: .regularExpression)
    }

    /// code_wrong: the blind value is the test's expectation and not what the new code returned; test_wrong: the reverse.
    static func blindVerdict(value: String, expected: String, actual: String) -> String {
        guard !value.isEmpty else { return "unclear" }
        let (v, e, a) = (normalized(value), normalized(expected), normalized(actual))
        if v == e && v != a { return "code_wrong" }
        if v == a && v != e { return "test_wrong" }
        return fieldwiseVerdict(value: value, expected: expected, actual: actual)
    }

    /// Whole values compared field by field (#46, 2026-10-12): the blind answer to a struct often differs from the test's
    /// literal only in how it is written (a field left out, `TMEntry` for `TransMemory.TMEntry`, `"acme"` for
    /// `Optional("acme")`), and c2-15's right answer (score 75, not 99) came back unclear. Only the fields where the expected
    /// and the actual value differ count; the answer must give at least half of them and agree with one side on all it gives.
    /// On the past rechecks it changed one unclear verdict (to test_wrong) and raised no new alarm.
    static func fieldwiseVerdict(value: String, expected: String, actual: String) -> String {
        func fields(_ text: String) -> [String: String] {
            let clean = text.replacingOccurrences(of: #"\b[A-Z]\w*\.(?=[A-Z])"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"Optional\((.*?)\)"#, with: "$1", options: .regularExpression)
            var out: [String: String] = [:]
            for match in SecondCandidate.matchGroups(#"(\w+):\s*("(?:[^"\\]|\\.)*"|[^,()\[\]]+)"#, in: clean) where match.count == 2 {
                out[match[0]] = match[1].trimmingCharacters(in: .whitespaces)
            }
            return out
        }
        let (v, e, a) = (fields(value), fields(expected), fields(actual))
        let differing = e.keys.filter { a[$0] != nil && e[$0] != a[$0] }
        let present = differing.filter { v[$0] != nil }
        guard !differing.isEmpty, present.count >= max(1, differing.count / 2) else { return "unclear" }
        if present.allSatisfy({ v[$0] == e[$0] }) { return "code_wrong" }
        if present.allSatisfy({ v[$0] == a[$0] }) { return "test_wrong" }
        return "unclear"
    }

    /// The 要確認 line in the user's words (2026-10-09: "payouts.map(\\.withholding): 期待 [5, 4]" means nothing to someone
    /// who does not read code). The model only names the situation and the value; the two numbers are the measured ones.
    /// Without its words, the expression is shown as before.
    static func plainExample(answer: String, failure: ExpectationFailure) -> String {
        let field = { (name: String) in
            SecondCandidate.matches("(?m)^\\s*\\**\(name):\\**\\s*(.+?)\\s*$", in: answer).last?
                .trimmingCharacters(in: CharacterSet(charactersIn: "` ")) ?? ""
        }
        let (situation, quantity) = (field("CASE"), field("WHAT"))
        let readable = { (value: String) in value == "throws" ? "エラー" : value.replacingOccurrences(of: "#\"", with: "\"")
            .replacingOccurrences(of: "\"#", with: "\"") }
        guard !situation.isEmpty, !quantity.isEmpty, !situation.contains("("), !quantity.contains("(") else {
            return "\(failure.expression): 依頼から計算すると \(readable(failure.expected))、今回の修正では \(readable(failure.actual))"
        }
        let trimmed = situation.hasSuffix("。") ? String(situation.dropLast()) : situation
        return "\(trimmed) → \(quantity)が、依頼から計算すると「\(readable(failure.expected))」、今回の修正では「\(readable(failure.actual))」"
    }

    /// Same value, same text: raw-string quotes, spaces, digit separators (5_000) and a trailing ` }` / `)` left over from the
    /// #expect line (c2-09 "9_900 }") do not count.
    /// The compact format the examiner writes (backlog #33); the harness turns each block into a Swift test.
    static let compactFormat = """
    Do NOT write Swift test code. Write each test as a short block, in this exact format (no other text):
    ### <testNameInCamelCase>
    aspect: a|b|c|d
    setup: <one Swift statement, optional; repeat the line for more statements>
    call: <one Swift expression that produces the observed value>
    then exactly ONE of these lines:
    expect: <a Swift expression for the value the request requires>
    property: <a Swift boolean expression about `result` that the request requires, e.g. result >= 0>
    throws: yes   (input that must be rejected with an error)
    With property:, add one more line: rule: <the same rule in Japanese, one short sentence without code, with the input \
    values, e.g. 介助者の無料券を含む8枚の注文では団体割引にならない>
    Make each call produce ONE field, number, flag or label the request talks about (e.g. `quote(for: order)?.total`, \
    `match(a, b)?.isExact`, `report.rows.map(\\.label)`), not a whole struct. Expect nil or an empty result only \
    when the request or the code says there is none; "as before" means the old behaviour, not no result.
    """

    /// Swift Testing source for the compact blocks, the kind of each test (expect / property / throws) and each property's
    /// rule. A literal check reads the value first (`let observed`): with `try` inside #expect, Swift Testing does not show
    /// the observed value and the blind recheck needs it.
    static func compactTests(_ response: String, module: String) -> (String, [String: String], [String: String]) {
        var tests: [String] = [], kinds: [String: String] = [:], rules: [String: String] = [:]
        for block in response.components(separatedBy: "###").dropFirst() {
            let lines = block.components(separatedBy: "\n")
            let base = lines[0].filter { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !base.isEmpty else { continue }
            let name = "examiner_" + base
            var setup: [String] = [], fields: [String: String] = [:]
            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
                guard let colon = trimmed.firstIndex(of: ":") else { continue }
                let key = String(trimmed[..<colon])
                let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " `"))
                guard ["aspect", "setup", "call", "expect", "property", "throws", "rule"].contains(key), !value.isEmpty else { continue }
                if key == "setup" { setup.append(value) } else { fields[key] = value }
            }
            // The model often writes a rule about `result` under expect: (c2-09); it is a property.
            if let expect = fields["expect"], expect.range(of: #"(?<![\w.])result\b"#, options: .regularExpression) != nil {
                fields["property"] = expect; fields["expect"] = nil
            }
            guard let call = fields["call"], !kinds.keys.contains(name) else { continue }
            var body = setup.map { "    " + $0 + "\n" }.joined()
            if fields["throws"]?.lowercased().hasPrefix("y") == true {
                body += "    #expect(throws: (any Error).self) { _ = try \(call) }\n"; kinds[name] = "throws"
            } else if let property = fields["property"] {
                // The card shows the rule in Japanese when the examiner gave one (c2-09 showed `result.systemFee == 8 * 330`).
                body += "    let result = try (\(call))\n    #expect(\(property))\n"; kinds[name] = "property"
                rules[name] = fields["rule"].flatMap { $0.contains("result") ? nil : $0 } ?? property
            } else if let expect = fields["expect"] {
                body += "    let observed = try (\(call))\n    #expect(observed == \(expect))\n"; kinds[name] = "expect"
            } else { continue }
            tests.append("@Test func \(name)() throws {\n\(body)}\n")
        }
        return ("import Foundation\nimport Testing\n@testable import \(module)\n\n" + tests.joined(separator: "\n"), kinds, rules)
    }

    /// The aspect (a, b, c or d) of each compact block, by test name.
    static func compactAspects(_ response: String) -> [String: String] {
        var aspects: [String: String] = [:]
        for block in response.components(separatedBy: "###").dropFirst() {
            let lines = block.components(separatedBy: "\n")
            let base = lines[0].filter { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !base.isEmpty, let line = lines.first(where: { $0.replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespaces).hasPrefix("aspect:") }) else { continue }
            aspects["examiner_" + base] = line.replacingOccurrences(of: "**", with: "").components(separatedBy: ":")[1]
                .trimmingCharacters(in: .whitespaces).lowercased().prefix(1).description
        }
        return aspects
    }

    static func normalized(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        while value.last == "}" { value.removeLast(); value = value.trimmingCharacters(in: .whitespaces) }
        // (1) from the compact format; an unbalanced ) left over from the #expect line
        while value.hasPrefix("("), value.hasSuffix(")"), value.filter({ $0 == "(" }).count == value.filter({ $0 == ")" }).count {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if value.filter({ $0 == ")" }).count > value.filter({ $0 == "(" }).count, value.last == ")" { value.removeLast() }
        return value.replacingOccurrences(of: #"(?<=\d)_(?=\d)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "#\"", with: "\"").replacingOccurrences(of: "\"#", with: "\"")
            .filter { !$0.isWhitespace }
    }

    static func failureDetail(_ name: String, in output: String) -> String {
        let lines = output.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("Test \(name)()") && $0.contains("recorded an issue") }) else {
            return lines.filter { $0.contains(name) }.prefix(3).joined(separator: "\n")
        }
        return lines[start..<min(lines.count, start + 8)].joined(separator: "\n")
    }
}
