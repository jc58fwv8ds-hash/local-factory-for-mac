import Foundation

/// A model or data file the code names that the project does not have (2026-11-11: 14Translate built and its tests passed,
/// but it loaded 「plamo-7b-q4_k_m.gguf」 while the project holds 「plamo-3-translate-0.8b-Q4_K_M.gguf」, so the app could
/// never translate). A passing build cannot see it; the autopilot gives it to the file as an error to fix.
public enum MissingResourceCheck {
    static let extensions = ["gguf", "mlmodel", "mlmodelc", "mlpackage", "onnx", "safetensors", "tflite"]

    public static func diagnostics(rootURL: URL) -> [BuildFailureDiagnostic] {
        let present = resourceFiles(under: rootURL)
        var result: [BuildFailureDiagnostic] = []
        for path in TestFailureAnalyzer.swiftFiles(under: rootURL) where !path.contains("Tests/") {
            guard let text = try? String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                for name in namedFiles(in: line) where !present.contains(name.lowercased()) {
                    let ext = (name as NSString).pathExtension.lowercased()
                    let same = present.filter { ($0 as NSString).pathExtension == ext }.sorted()
                    let have = same.isEmpty ? "同じ種類のファイルはプロジェクトにありません。"
                        : "プロジェクトにあるのは " + same.map { "「\(original($0, in: rootURL))」" }.joined(separator: "、") + " です。この名前に直してください。"
                    result.append(BuildFailureDiagnostic(validationKind: .build, relativePath: path, line: index + 1, column: nil,
                                                         message: "コードが読むファイル「\(name)」がプロジェクトにありません。" + have))
                }
            }
        }
        return result
    }

    /// File names in a line: a literal "name.gguf", or forResource: "name", withExtension: "gguf".
    static func namedFiles(in line: String) -> [String] {
        let joined = extensions.joined(separator: "|")
        var names = matches(#""([A-Za-z0-9_.\-]+\.(?:"# + joined + #"))""#, in: line)
        let pairs = matches(#"forResource:\s*"([A-Za-z0-9_.\-]+)"\s*,\s*withExtension:\s*"("# + joined + #")""#, in: line, groups: 2)
        names += stride(from: 0, to: pairs.count - 1, by: 2).map { pairs[$0] + "." + pairs[$0 + 1] }
        return names
    }

    private static func matches(_ pattern: String, in line: String, groups: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).flatMap { match in
            (1...groups).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
        }
    }

    /// Lowercased names of the model files anywhere in the project (ignored by git or not).
    static func resourceFiles(under root: URL) -> Set<String> {
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var names: Set<String> = []
        var count = 0
        while let url = entries.nextObject() as? URL, count < 20_000 {
            count += 1
            if SourceFilePolicy.isExcludedDirectory(url.lastPathComponent) { entries.skipDescendants(); continue }
            if extensions.contains(url.pathExtension.lowercased()) {
                names.insert(url.lastPathComponent.lowercased())
                if ["mlmodelc", "mlpackage"].contains(url.pathExtension.lowercased()) { entries.skipDescendants() }
            }
        }
        return names
    }

    private static func original(_ lowered: String, in root: URL) -> String {
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return lowered }
        while let url = entries.nextObject() as? URL {
            if SourceFilePolicy.isExcludedDirectory(url.lastPathComponent) { entries.skipDescendants(); continue }
            if url.lastPathComponent.lowercased() == lowered { return url.lastPathComponent }
        }
        return lowered
    }
}
