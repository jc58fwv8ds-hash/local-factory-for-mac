import Foundation
import HarnessCore
import HarnessExecution

/// Example check for the user (2026-10-09, backlog #11/#22/#34). Most false successes come from conventions the request does
/// not state or from a misreading of it; two models share such a misreading (c2-03), so no model check finds them, but the
/// user sees them in one concrete case. After the tests pass, a model picks 2-3 situations at the request's boundaries and
/// ambiguous points, names each in Japanese, and writes the Swift expression that shows the result. The harness runs the
/// expressions on the final code and on the code before the change (measured values, never the model's), and the model's
/// other readings of the request become one-click follow-up instructions. Nothing here changes the result of the task.
/// Like the examiner, it reads the visible acceptance tests as API examples (the user's exception of 2026-10-07).
enum ExampleCheckStage {
    struct Example: Equatable {
        var situation: String; var quantity: String; var setup: String; var expression: String; var alternatives: [String]
    }

    /// `seeds`: cases the user answered 違う on in the previous proposal; they are run first and, when they run without the
    /// visible tests' private helpers, become a protected test of the project (backlog #39).
    static func run(candidate: URL, root: URL, directory: URL, model: String, objective: String, originals: [String: String],
                    visibleTests: [String: String], permitted: [String], record: BatchRunRecord, seeds: [Example] = []) async {
        do {
            let examples = seeds + (try await propose(root: root, model: model, objective: objective, originals: originals,
                                                      visibleTests: visibleTests, permitted: permitted)).prefix(max(0, 3 - seeds.count))
            guard !examples.isEmpty, let testPath = visibleTests.keys.sorted().first else {
                record["exampleCheck"] = ["outcome": "noExamples"]; try record.save(); return
            }
            let target = String(testPath.split(separator: "/")[1])
            let module = target.hasSuffix("Tests") ? String(target.dropLast(5)) : target
            let source = testFile(examples, module: module)
            let after = try await values(source, candidate: candidate, root: root, target: target, visibleTests: visibleTests,
                                         evidence: directory.appendingPathComponent("examples-after"))
            let before = try await valuesBefore(source, candidate: candidate, root: root, originals: originals, target: target,
                                                visibleTests: visibleTests, evidence: directory.appendingPathComponent("examples-before"))
            let shown: [[String: Any]] = examples.enumerated().compactMap { index, example in
                guard let value = after[index + 1] else { return nil }   // did not compile or run on the final code
                var row: [String: Any] = ["situation": example.situation, "quantity": example.quantity, "after": value,
                                          "setup": example.setup, "expression": example.expression,
                                          "alternatives": example.alternatives, "agreed": index < seeds.count]
                if let old = before[index + 1] { row["before"] = old }
                return row
            }
            var check: [String: Any] = ["outcome": shown.isEmpty ? "noRunnableExamples" : "shown", "examples": shown]
            if !seeds.isEmpty, let agreed = try await agreedTest(seeds, candidate: candidate, root: root, target: target,
                                                                    module: module, visibleTests: visibleTests,
                                                                    evidence: directory.appendingPathComponent("examples-agreed")) {
                check["agreedTest"] = agreed
            }
            record["exampleCheck"] = check
            try record.save()
        } catch is CancellationError {
            return
        } catch {
            record["exampleCheck"] = ["outcome": "unavailable (\(error))"]; try? record.save()
        }
    }

    static let agreedFile = "LocalFactoryAgreedTests.swift"

    /// The agreed cases as tests with the value the new code gives, appended to the project's agreed-tests file, kept only
    /// if they pass on this copy without opening any private helper (the project's own tests keep theirs private).
    static func agreedTest(_ seeds: [Example], candidate: URL, root: URL, target: String, module: String,
                           visibleTests: [String: String], evidence: URL) async throws -> [String: String]? {
        let raw = rawValues(try await BatchExaminerStage.runExam(testFile(seeds, module: module), candidate: candidate, root: root,
            target: target, visibleTests: visibleTests, evidence: evidence.appendingPathExtension("values"), openHelpers: false))
        let stamp = String(Int(Date().timeIntervalSince1970))
        let tests: [String] = seeds.enumerated().compactMap { index, seed in
            guard let value = raw[index + 1] else { return nil }
            let literal = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return """
            /// \(seed.situation) → \(seed.quantity)(ユーザーが確かめた動き)
            @Test func agreed_\(stamp)_\(index + 1)() throws {
                \(seed.setup)
                let value: Any = \(seed.expression)
                #expect(String(describing: value) == "\(literal)")
            }
            """
        }
        guard !tests.isEmpty else { return nil }
        let path = "Tests/\(target)/\(agreedFile)"
        let existing = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        let content = (existing ?? "import Foundation\nimport Testing\n@testable import \(module)\n\n// Local Factory: 例の確認でユーザーが決めた動き\n")
            + "\n" + tests.joined(separator: "\n\n") + "\n"
        let output = try await BatchExaminerStage.runExam(content, candidate: candidate, root: root, target: target,
            visibleTests: visibleTests, evidence: evidence, openHelpers: false, fileName: agreedFile)
        let ran = Set(SecondCandidate.matches(#"✔ Test (agreed_\w+)\(\) passed"#, in: output))
        guard tests.indices.allSatisfy({ ran.contains("agreed_\(stamp)_\($0 + 1)") || raw[$0 + 1] == nil }), !ran.isEmpty else { return nil }
        return ["path": path, "content": content]
    }

    static func propose(root: URL, model: String, objective: String, originals: [String: String],
                        visibleTests: [String: String], permitted: [String]) async throws -> [Example] {
        var final: [String: String] = [:]
        for path in permitted where path.hasPrefix("Sources/") {
            final[path] = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let map = String(decoding: try JSONSerialization.data(withJSONObject: originals, options: [.sortedKeys]), as: UTF8.self)
        let prompt = """
        A developer changed a Swift package for this request:
        \(objective)

        The production code BEFORE the change is the EDITABLE file map in the system message (nothing is edited in this step).
        EDITABLE: \(map)
        READ-ONLY: {}

        Declarations of the production code after the change:
        \(final.sorted { $0.key < $1.key }.map { "// \($0.key)\n" + SecondCandidate.signatures($0.value) }.joined(separator: "\n"))

        Existing tests (their fixtures and helpers may be used):
        \(visibleTests.sorted { $0.key < $1.key }.map { "// \($0.key)\n\($0.value)" }.joined(separator: "\n"))

        The user will check the change by looking at 2 or 3 concrete cases. Pick the cases where a wrong reading of the request \
        would show: its boundaries (the value exactly at a limit), its exceptions, and anything the request leaves open. For \
        each case write exactly these lines:
        ### <number>
        CASE: <Japanese, one short sentence without code: the situation with EVERY input value written out, so the user can \
        check the result by hand, e.g. 小テストが3回(80点・40点・免除)で、低い方から1回除外するとき — never only "最低点の回が免除だった場合">
        WHAT: <Japanese, a few words without code: the value shown, with its unit, e.g. 送料(円); for an internal unit say how to read it, e.g. 得点率(1万分率、8500 は 85%)>
        SETUP: <Swift statements that prepare the case on one line, or nothing>
        EXPR: <one Swift expression using the declared API that gives that value as a number, text, true/false or a list>
        ALT: <Japanese, one short instruction: another plausible reading of the request for this case, written as a request to change it>
        ALT: <optionally a second one>
        Nothing else.
        """
        let response = try await DogfoodLocalProposalRunner.collect(.init(runtime: .ollama, modelIdentifier: model,
            messages: SharedContextMessages.messages(for: prompt), maximumOutputTokens: 1500))
        return parse(response)
    }

    static func parse(_ text: String) -> [Example] {
        text.components(separatedBy: "###").dropFirst().compactMap { block in
            var fields: [String: [String]] = [:]
            for line in block.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
                guard let colon = trimmed.firstIndex(of: ":") else { continue }
                let key = String(trimmed[..<colon]), value = trimmed[trimmed.index(after: colon)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " `"))
                guard ["CASE", "WHAT", "SETUP", "EXPR", "ALT"].contains(key), !value.isEmpty else { continue }
                fields[key, default: []].append(value)
            }
            guard let situation = fields["CASE"]?.first, let quantity = fields["WHAT"]?.first,
                  let expression = fields["EXPR"]?.first else { return nil }
            return Example(situation: situation, quantity: quantity,
                           setup: fields["SETUP"]?.first.map { $0 == "nothing" || $0 == "なし" ? "" : $0 } ?? "",
                           expression: expression, alternatives: Array((fields["ALT"] ?? []).prefix(2)))
        }.prefix(3).map { $0 }
    }

    /// One test per example that prints `LF_EXAMPLE_<n>=<value>` (or エラー when it throws).
    static func testFile(_ examples: [Example], module: String) -> String {
        "import Testing\n@testable import \(module)\n\n" + examples.enumerated().map { index, example in
            """
            @Test func lfExample\(index + 1)() {
                do {
                    \(example.setup)
                    let value: Any = \(example.expression)
                    print("LF_EXAMPLE_\(index + 1)=" + String(describing: value))
                } catch {
                    print("LF_EXAMPLE_\(index + 1)=エラー")
                }
            }
            """
        }.joined(separator: "\n\n") + "\n"
    }

    /// Runs the example file on a copy of `root`; examples that do not compile are dropped and the rest still run.
    static func values(_ source: String, candidate: URL, root: URL, target: String, visibleTests: [String: String],
                       evidence: URL) async throws -> [Int: String] {
        var tests = source
        var output = ""
        for round in 0..<3 {
            output = try await BatchExaminerStage.runExam(tests, candidate: candidate, root: root, target: target,
                visibleTests: visibleTests, evidence: evidence.appendingPathExtension("\(round)"))
            let bad = Set(SecondCandidate.matches(#"ExaminerScenarioTests\.swift:(\d+):\d+: error:"#, in: output).compactMap(Int.init))
            guard !bad.isEmpty else { break }
            let (kept, removed) = BatchExaminerStage.prune(tests, errorLines: bad)
            guard !removed.isEmpty else { break }
            tests = kept
        }
        return printed(output)
    }

    /// The same examples on the package before the change (new files removed, changed files restored).
    static func valuesBefore(_ source: String, candidate: URL, root: URL, originals: [String: String], target: String,
                             visibleTests: [String: String], evidence: URL) async throws -> [Int: String] {
        let before = try beforeCopy(of: root, originals: originals)
        defer { try? FileManager.default.removeItem(at: before) }
        return try await values(source, candidate: candidate, root: before.resolvingSymlinksInPath(), target: target,
                                visibleTests: visibleTests, evidence: evidence)
    }

    /// A copy of `root` with the production code as it was before the change (new files removed); the caller removes it.
    static func beforeCopy(of root: URL, originals: [String: String]) throws -> URL {
        let before = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-before-" + UUID().uuidString.prefix(6))
        try SecondCandidate.copy(root, to: before)
        let sources = before.appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        for url in files where url.pathExtension == "swift" {
            let relative = "Sources/" + url.path.dropFirst(sources.path.count + 1)
            if originals[relative] == nil { try? FileManager.default.removeItem(at: url) }
        }
        for (path, text) in originals { try text.write(to: before.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        return before
    }

    /// Only lines the tests printed: a compiler diagnostic quotes the source line `print("LF_EXAMPLE_3=エラー")` too (c2-02).
    /// The values exactly as Swift printed them (for the agreed tests' expectations).
    static func rawValues(_ output: String) -> [Int: String] {
        var values: [Int: String] = [:]
        for line in output.components(separatedBy: "\n") {
            guard let range = line.range(of: #"^LF_EXAMPLE_(\d+)="#, options: .regularExpression) else { continue }
            values[Int(line[range].dropFirst("LF_EXAMPLE_".count).dropLast()) ?? 0] = String(line[range.upperBound...])
        }
        return values
    }

    static func printed(_ output: String) -> [Int: String] {
        var values: [Int: String] = [:]
        for line in output.components(separatedBy: "\n") {
            guard let range = line.range(of: #"^LF_EXAMPLE_(\d+)="#, options: .regularExpression) else { continue }
            let number = Int(line[range].dropFirst("LF_EXAMPLE_".count).dropLast()) ?? 0
            values[number] = readable(String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return values
    }

    /// Swift's `Optional(8500)` / `nil` / quoted text, as a person would write them.
    static func readable(_ value: String) -> String {
        var text = value
        while text.hasPrefix("Optional("), text.hasSuffix(")") { text = String(text.dropFirst(9).dropLast()) }
        if text == "nil" { return "なし" }
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\""), !text.dropFirst().dropLast().contains("\"") {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
