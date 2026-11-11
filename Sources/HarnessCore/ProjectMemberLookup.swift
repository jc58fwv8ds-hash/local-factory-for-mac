import Foundation

/// The names a type made in this project really has, read from its source, for a build error that says it has no such
/// member (2026-11-10: wiring 14Translate's parts together the local model called SpeechListener.transcript and
/// PlamoTranslator.loadModel(), names it guessed; the SDK lookup only knows Apple's types).
public enum ProjectMemberLookup {
    public static func hint(for message: String, projectRoot: URL) -> String? {
        guard let (type, _) = SDKMemberLookup.missingMember(in: message) else { return nil }
        let names = members(of: type, projectRoot: projectRoot)
        guard !names.isEmpty else { return nil }
        return "参考(このプロジェクトのソースより): \(type) に実在する名前: " + names.prefix(30).joined(separator: ", ")
    }

    /// The members other files can use: properties, methods and initialisers that are not private.
    public static func members(of type: String, projectRoot: URL) -> [String] {
        for path in TestFailureAnalyzer.swiftFiles(under: projectRoot) {
            guard let text = try? String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8),
                  text.range(of: #"\b(class|struct|actor|enum)\s+\#(type)\b"#, options: .regularExpression) != nil
            else { continue }
            return declarations(in: typeBody(of: type, in: text))
        }
        return []
    }

    /// The type's own lines: those one brace deep inside its declaration, not the bodies of its functions.
    static func typeBody(of type: String, in text: String) -> String {
        var lines: [String] = []
        var depth = 0
        var inside = false
        for line in text.components(separatedBy: "\n") {
            if !inside, line.range(of: #"\b(class|struct|actor|enum)\s+\#(type)\b"#, options: .regularExpression) != nil {
                inside = true
            }
            let before = depth
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if inside && before == 1 { lines.append(line) }
            if inside && before > 0 && depth == 0 { break }
        }
        return lines.joined(separator: "\n")
    }

    static func declarations(in text: String) -> [String] {
        var names: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("private ") || line.hasPrefix("fileprivate ") || line.hasPrefix("//") { continue }
            let stripped = line.replacingOccurrences(
                of: #"^(@\w+(\([^)]*\))?\s+)*((public|internal|nonisolated|static|final|override|mutating|private\(set\))\s+)*"#,
                with: "", options: .regularExpression)
            if let match = stripped.range(of: #"^(var|let)\s+\w+"#, options: .regularExpression) {
                names.append(String(stripped[match].split(separator: " ").last!))
            } else if let match = stripped.range(of: #"^func\s+\w+\([^)]*\)"#, options: .regularExpression) {
                names.append(String(stripped[match].dropFirst(5)))
            } else if let match = stripped.range(of: #"^init\([^)]*\)"#, options: .regularExpression) {
                names.append(String(stripped[match]))
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
