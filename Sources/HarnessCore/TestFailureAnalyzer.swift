import Foundation

/// Test failures turned into something to fix (2026-11-10, the user: 「シミュレータでは GPU を使わない直しを入れる発想が
/// ユーザーに出来るとは思えないのでそこら辺の判断をアプリにして欲しい」). A failed Swift Testing or XCTest case names its test
/// file; the file it tests is found by name (PlamoTranslatorTests → PlamoTranslator.swift), and the failure, with what the
/// log shows about where it ran, becomes that file's repair. The fixes for well-known traps are added by BuildErrorAdvice.
public enum TestFailureAnalyzer {
    /// 「✘ Test name() recorded an issue at File.swift:12:9: Expectation failed: …」 and the lines after it that show values.
    static let swiftTesting = try! NSRegularExpression(
        pattern: #"Test (\w+)\(\) recorded an issue at ([\w+.-]+\.swift):(\d+):\d+: (.+)"#)

    public static func diagnostics(output: String, rootURL: URL, kind: ProjectValidationKind) -> [BuildFailureDiagnostic] {
        let lines = output.components(separatedBy: "\n")
        let context = logContext(output)
        var found: [BuildFailureDiagnostic] = []
        var seen = Set<String>()
        for (index, line) in lines.enumerated() {
            guard let match = swiftTesting.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let name = Range(match.range(at: 1), in: line).map({ String(line[$0]) }),
                  let file = Range(match.range(at: 2), in: line).map({ String(line[$0]) }),
                  let message = Range(match.range(at: 4), in: line).map({ String(line[$0]) }) else { continue }
            // The values Swift Testing prints under the expectation (「↳ result → ""」).
            let values = lines[(index + 1)...].prefix(6).prefix { $0.contains("↳") }
                .map { $0.replacingOccurrences(of: "↳", with: "").trimmingCharacters(in: .whitespaces) }
            guard let target = testedFile(for: file, under: rootURL), seen.insert(name + message).inserted else { continue }
            let detail = "テスト \(name) が失敗(\(file)): \(message)"
                + (values.isEmpty ? "" : "(" + values.joined(separator: "、") + ")")
                + (context.isEmpty ? "" : " [記録: " + context.joined(separator: ", ") + "]")
            found.append(BuildFailureDiagnostic(validationKind: kind, relativePath: target, line: nil, column: nil,
                                                message: String(detail.prefix(600))))
            if found.count >= 4 { break }
        }
        return found
    }

    /// What the log says about where the test ran, for the advice on well-known traps.
    static func logContext(_ output: String) -> [String] {
        let lowered = output.lowercased()
        var tags: [String] = []
        if lowered.contains("iphonesimulator") || lowered.contains("simulator") { tags.append("simulator") }
        if lowered.contains("ggml_metal") || lowered.contains("mtl0") { tags.append("ggml_metal") }
        if lowered.contains("llama_") || lowered.contains(".gguf") { tags.append("llama") }
        if lowered.contains("mlx") { tags.append("mlx") }
        return tags
    }

    /// The source file a test file tests: 「FooTests.swift」 or 「FooTest.swift」 → 「Foo.swift」 in the app, else the test file.
    static func testedFile(for testFile: String, under root: URL) -> String? {
        let base = (testFile as NSString).deletingPathExtension
        let subject = base.hasSuffix("Tests") ? String(base.dropLast(5)) : base.hasSuffix("Test") ? String(base.dropLast(4)) : base
        let files = swiftFiles(under: root)
        if let source = files.first(where: { ($0 as NSString).lastPathComponent == subject + ".swift" }) { return source }
        return files.first { ($0 as NSString).lastPathComponent == testFile }
    }

    static func swiftFiles(under root: URL) -> [String] {
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var paths: [String] = []
        let prefix = root.standardizedFileURL.path + "/"
        while let url = entries.nextObject() as? URL {
            if SourceFilePolicy.isExcludedDirectory(url.lastPathComponent) { entries.skipDescendants(); continue }
            if url.pathExtension == "swift", url.standardizedFileURL.path.hasPrefix(prefix) {
                paths.append(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
            }
            if paths.count > 2_000 { break }
        }
        return paths
    }
}
