import Foundation

/// A dictionary literal with the same key twice: it builds, and stops the app the moment the line runs (2026-11-12:
/// 14Translate's reading table listed 「二頭獣」 seven times). Found after a passing build, fixed like a build error.
public enum DuplicateLiteralKeyCheck {
    public static func diagnostics(rootURL: URL) -> [BuildFailureDiagnostic] {
        TestFailureAnalyzer.swiftFiles(under: rootURL).flatMap { path -> [BuildFailureDiagnostic] in
            guard let text = try? String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8) else { return [] }
            return duplicates(in: text).map { line, key in
                BuildFailureDiagnostic(validationKind: .build, relativePath: path, line: line, column: nil,
                                       message: "辞書に同じ見出し「\(key)」が 2 回以上あります。ビルドは通っても、この行が動いた時点でアプリが落ちます。重なりを 1 つにしてください。")
            }
        }
    }

    /// (1-based line of the second appearance, key) for string keys repeated within one `[ … ]` literal.
    static func duplicates(in text: String) -> [(Int, String)] {
        let lines = text.components(separatedBy: "\n")
        var result: [(Int, String)] = []
        var keys: [String: Int] = [:]
        var depth = 0
        guard let regex = try? NSRegularExpression(pattern: #"^\s*"((?:[^"\\]|\\.)*)"\s*:"#) else { return [] }
        for (index, line) in lines.enumerated() {
            if depth == 0 { keys = [:] }
            if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), depth > 0,
               let range = Range(match.range(at: 1), in: line) {
                let key = String(line[range])
                if keys[key] != nil { if !result.contains(where: { $0.1 == key }) { result.append((index + 1, key)) } } else { keys[key] = index }
            }
            depth += line.filter { $0 == "[" }.count - line.filter { $0 == "]" }.count
            depth = max(0, depth)
        }
        return result
    }
}
