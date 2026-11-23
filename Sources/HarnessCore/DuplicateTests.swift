import Foundation

/// A failing test that checks exactly what passing tests of another file already check: the same work done twice, one
/// copy right and one wrong (2026-11-18: the Factory had put a second number reader into 14Translate's translator with its
/// own test; the reading file's tests for the same 「さんぼん」「さんぜんごひゃくえん」「せんこ」 passed, the translator's copy
/// failed through dozens of repairs, and the user said: 「ファクトリーが自律的に同様の不具合に対応できるように」).
public enum DuplicateTests {
    public struct Duplicate: Equatable, Sendable {
        public let testFile: String
        public let testName: String
        public let source: String?
        public let otherTestFile: String
        public let otherSource: String?
        public let expected: [String]

        /// What to ask, in plain words, for one copy to remain.
        public var request: String {
            let name = { (path: String?) in path.map { ($0 as NSString).lastPathComponent } ?? "" }
            return "\(name(testFile)) の \(testName) は、\(name(otherTestFile)) と同じこと(" + expected.prefix(4).map { "「\($0)」" }.joined(separator: "、")
                + ")を確かめていて、\(name(otherTestFile)) のほうは通っています。同じ処理を二か所に持たないよう、"
                + (source.map { "\(name($0)) にある同じ処理と、" } ?? "")
                + "\(name(testFile)) の \(testName) のテストを外し、"
                + (otherSource.map { "その処理が要る所では \(name($0)) の処理を使ってください。" } ?? "もう一方の処理を使ってください。")
                + "\(name(otherTestFile)) のテストはそのまま残してください。"
        }
    }

    public static func find(diagnostics: [BuildFailureDiagnostic], rootURL: URL) -> [Duplicate] {
        let regex = try! NSRegularExpression(pattern: #"テスト (\w+) が失敗\(([\w+.-]+\.swift)\)"#)
        let failing = diagnostics.compactMap { diagnostic -> (name: String, file: String)? in
            let message = diagnostic.message
            guard let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let name = Range(match.range(at: 1), in: message), let file = Range(match.range(at: 2), in: message) else { return nil }
            return (String(message[name]), String(message[file]))
        }
        guard !failing.isEmpty else { return [] }
        let failingFiles = Set(failing.map(\.file))
        let files = TestFailureAnalyzer.swiftFiles(under: rootURL)
        let tests = files.filter { $0.contains("Tests") }
        func text(_ path: String) -> String? { try? String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8) }
        var found: [Duplicate] = []
        var seen = Set<String>()
        for (name, file) in failing where seen.insert(file + name).inserted {
            guard let path = tests.first(where: { ($0 as NSString).lastPathComponent == file }), let body = text(path).flatMap({ testBody(name, in: $0) })
            else { continue }
            let expected = expectedValues(in: body)
            guard !expected.isEmpty else { continue }
            for other in tests where (other as NSString).lastPathComponent != file && !failingFiles.contains((other as NSString).lastPathComponent) {
                guard let otherText = text(other), expected.allSatisfy({ otherText.contains("\"\($0)\"") }) else { continue }
                found.append(Duplicate(testFile: path, testName: name, source: TestFailureAnalyzer.testedFile(for: file, under: rootURL),
                                       otherTestFile: other, otherSource: TestFailureAnalyzer.testedFile(for: (other as NSString).lastPathComponent, under: rootURL),
                                       expected: expected))
                break
            }
        }
        return found
    }

    /// The lines of one test, from its `func name(` to the next test.
    static func testBody(_ name: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("func \(name)(") }) else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.contains("@Test") || $0.range(of: #"func test\w*\("#, options: .regularExpression) != nil } ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }

    /// The values a test compares with: 「== "X"」 and 「XCTAssertEqual(…, "X")」.
    static func expectedValues(in body: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(?:==\s*|XCTAssertEqual\([^,]+,\s*)"([^"]+)""#)
        var values: [String] = []
        for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            if let range = Range(match.range(at: 1), in: body), !values.contains(String(body[range])) { values.append(String(body[range])) }
        }
        return values
    }
}
