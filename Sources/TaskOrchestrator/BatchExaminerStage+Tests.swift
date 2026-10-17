import Foundation
import HarnessCore
import HarnessExecution

/// Writing, pruning and reading the examiner's tests, and the blind recheck's comparison (split out of
/// BatchExaminerStage.swift, 2026-10-18).
extension BatchExaminerStage {
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
