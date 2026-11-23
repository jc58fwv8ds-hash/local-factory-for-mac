import Foundation

/// The project's own Swift functions that an erroring call uses, as they are declared, for errors about a call's arguments
/// (2026-11-16: a test called `translate(_:sourceLang:glossary:)` with its arguments in the wrong order, and six repairs of the
/// test, shown only the test, never saw that the function takes `glossary` first).
public enum ProjectCallLookup {
    static let argumentErrors = [
        "must precede argument", "missing argument", "extra argument", "incorrect argument label",
        "extraneous argument label", "missing arguments", "argument passed to call that takes no arguments",
        "to expected argument type", "no exact matches in call"
    ]

    public static func declarations(messages: [String], lines: [String], projectRoot: URL, limit: Int = 6) -> [String] {
        guard messages.contains(where: { message in argumentErrors.contains(where: message.contains) }) else { return [] }
        let names = Set(lines.flatMap(calledNames))
        // A type made with `Name(…)`: its initializers (2026-11-16: a test made SlangGlossaryStore(entries:) six times).
        let types = Set(lines.flatMap(madeTypes))
        guard !names.isEmpty || !types.isEmpty else { return [] }
        var found: [String] = []
        for file in swiftFiles(in: projectRoot) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var currentType: String?
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if let range = line.range(of: #"\b(class|struct|actor|enum) ([A-Z][A-Za-z0-9_]*)"#, options: .regularExpression) {
                    currentType = String(line[range].split(separator: " ").last ?? "")
                }
                let madeHere = currentType.map(types.contains) == true && line.range(of: #"^(public |private |convenience |required |nonisolated |@\w+ )*init[?!]?\s*\("#, options: .regularExpression) != nil
                let called = declaredName(line).map(names.contains) == true
                guard madeHere || called else { continue }
                let prefix = madeHere ? "\(currentType ?? "") の " : ""
                let entry = file.lastPathComponent + ": " + prefix + String(line.prefix(200)).trimmingCharacters(in: CharacterSet(charactersIn: " {"))
                if !found.contains(entry) { found.append(entry) }
                if found.count == limit { return found }
            }
        }
        return found
    }

    /// Names called on a line: `name(` not preceded by `func`.
    static func calledNames(_ line: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(?<!func )\b([a-z][A-Za-z0-9_]*)\s*\("#)
        let range = NSRange(line.startIndex..., in: line)
        let skip: Set<String> = ["if", "guard", "while", "switch", "return", "try", "await", "print", "expect", "require"]
        return regex.matches(in: line, range: range).compactMap { match in
            Range(match.range(at: 1), in: line).map { String(line[$0]) }
        }.filter { !skip.contains($0) }
    }

    /// Types made on a line: `Name(` with a capital first letter.
    static func madeTypes(_ line: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\b([A-Z][A-Za-z0-9_]*)\s*\("#)
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            Range(match.range(at: 1), in: line).map { String(line[$0]) }
        }
    }

    static func declaredName(_ line: String) -> String? {
        guard let range = line.range(of: #"\bfunc ([a-z][A-Za-z0-9_]*)\s*[(<]"#, options: .regularExpression) else { return nil }
        return String(line[range].dropFirst(5).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    static func swiftFiles(in root: URL) -> [URL] {
        let skipped: Set<String> = [".build", ".git", "DerivedData", "Pods", "Frameworks", "build"]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if url.pathExtension == "swift" { files.append(url) }
            if files.count > 400 { break }
        }
        return files.sorted { $0.path < $1.path }
    }
}
