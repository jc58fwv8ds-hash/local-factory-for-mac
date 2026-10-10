import Foundation
import HarnessCore

/// Bounded compiler-guided repair: pure decisions only. The runner owns I/O and at
/// most one repair attempt. Diagnostics in protected/test files are never shown to
/// the model (they would leak hidden acceptance tests) and end the task instead.
public enum CompilerRepair {
    public struct Diagnostic: Codable, Equatable, Sendable {
        public let path: String
        public let line: Int
        public let column: Int
        public let message: String
    }

    public enum FailureClass: String, Codable, Sendable {
        case typeMismatch, missingMember, undefinedSymbol, syntax, other
    }

    public enum Eligibility: String, Codable, Sendable {
        case repairable, notCompileFailure, hiddenOrProtectedDiagnostic, scopeExpansionRequired
        /// The compiler asks for a change in a read-only evidence file: repair never
        /// widens EditableTargets; this is a Context / target-selection / task-design issue.
        case readOnlyEvidenceDiagnostic
    }

    /// Parses `path:line:col: error: message` lines; paths are made root-relative.
    public static func diagnostics(output: String, root: URL) -> [Diagnostic] {
        let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var seen = Set<String>()
        return output.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            guard let range = line.range(of: ": error: ") else { return nil }
            let location = line[..<range.lowerBound].split(separator: ":")
            guard location.count >= 3, let row = Int(location[location.count - 2]),
                  let column = Int(location[location.count - 1]) else { return nil }
            var path = location.dropLast(2).joined(separator: ":")
            if path.hasPrefix(prefix) { path.removeFirst(prefix.count) } else if path.hasPrefix("/") { path = "<outside>" + path }
            let item = Diagnostic(path: path, line: row, column: column,
                message: String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
            return seen.insert("\(item.path):\(item.line):\(item.column):\(item.message)").inserted ? item : nil
        }
    }

    public static func classify(_ diagnostics: [Diagnostic]) -> FailureClass {
        guard let message = diagnostics.first?.message.lowercased() else { return .other }
        if message.contains("has no member") { return .missingMember }
        if message.contains("cannot convert") || message.contains("no exact matches") ||
            message.contains("argument type") || message.contains("mismatch") { return .typeMismatch }
        if message.contains("cannot find") || message.contains("unresolved") { return .undefinedSymbol }
        if message.hasPrefix("expected") || message.contains("consecutive statements") { return .syntax }
        return .other
    }

    public static func eligibility(_ diagnostics: [Diagnostic], permitted: Set<String>,
                                   protected: Set<String>, readOnly: Set<String> = []) -> Eligibility {
        guard !diagnostics.isEmpty else { return .notCompileFailure }
        if diagnostics.contains(where: { protected.contains($0.path) || isTest($0.path) }) {
            return .hiddenOrProtectedDiagnostic
        }
        if diagnostics.contains(where: { readOnly.contains($0.path) }) { return .readOnlyEvidenceDiagnostic }
        return diagnostics.allSatisfy { permitted.contains($0.path) } ? .repairable : .scopeExpansionRequired
    }

    /// Files a repair may touch: never beyond the current EditableTargets.
    public static func repairFiles(diagnostics: [Diagnostic], firstPass: [String], editable: Set<String>) -> [String] {
        Set(diagnostics.map(\.path)).union(firstPass).filter { editable.contains($0) }.sorted()
    }

    /// The model's own diff (changed lines only), used in repair and replan feedback.
    public static func renderDiff(_ proposals: [FileChangeProposal]) -> String {
        proposals.map { p in
            "--- \(p.relativePath)\n" + p.diffLines.filter { $0.kind != .context }
                .map { ($0.kind == .addition ? "+" : "-") + $0.text }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// Minimal repair context: objective, the model's own diff, relevant diagnostics,
    /// and numbered windows of the current file around each error. Nothing else.
    public static func prompt(objective: String, proposals: [FileChangeProposal],
                              current: [String: String], diagnostics: [Diagnostic],
                              window: Int = 10, maxEdits: Int, maxLines: Int, declarations: String = "") -> String {
        let diff = proposals.map { p in
            "--- \(p.relativePath)\n" + p.diffLines.filter { $0.kind != .context }
                .map { ($0.kind == .addition ? "+" : "-") + $0.text }.joined(separator: "\n")
        }.joined(separator: "\n")
        let shown = diagnostics.prefix(8)
        var snippets: [String] = []
        for path in Array(Set(shown.map(\.path))).sorted() {
            guard let lines = current[path]?.components(separatedBy: "\n") else { continue }
            var keep = Set<Int>()
            for d in shown where d.path == path {
                keep.formUnion(max(1, d.line - window)...min(lines.count, max(1, d.line + window)))
            }
            let body = keep.sorted().prefix(80).map { "\($0): \(lines[$0 - 1])" }.joined(separator: "\n")
            snippets.append("=== \(path) (current, numbered excerpt)\n\(body)")
        }
        return """
        Your previous edit for this objective does not compile. Fix only the compile errors.
        Objective: \(objective)
        Your previous diff:
        \(diff)
        Compiler errors:
        \(shown.map { "\($0.path):\($0.line):\($0.column): \($0.message)" }.joined(separator: "\n"))
        \(snippets.joined(separator: "\n"))
        \(declarations.isEmpty ? "" : "Declarations of the types named in the errors (read-only; use their real members):\n" + declarations)
        Return JSON only: {"edits":[{"operation":"replace_exact","file":"relative path","expected_old_text":"exact current text without line numbers","new_text":"replacement"}]}.
        Edit only the files listed above. At most \(maxEdits) edits and \(maxLines) total old+new lines. Preserve indentation.
        """
    }

    /// Full declarations (struct/enum/class/actor/protocol/extension, up to 60 lines each) of the package types quoted in the
    /// diagnostics, e.g. 'Token' in "value of type 'Token' has no member 'text'": the excerpt around the error rarely shows
    /// them, and the model otherwise guesses members (offline replay: b5-27 compiles only with them).
    public static func typeDeclarations(diagnostics: [Diagnostic], sources: [String: String], limit: Int = 6000) -> String {
        let standard: Set<String> = ["String", "Int", "Double", "Bool", "Array", "Dictionary", "Set", "Optional", "Character",
                                     "Substring", "SubSequence", "Equatable", "Hashable", "Comparable", "Codable", "Sendable"]
        var names = Set<String>()
        for message in diagnostics.map(\.message) {
            for quoted in matches(#"'([^']+)'"#, in: message) {
                names.formUnion(matches(#"\b([A-Z][A-Za-z0-9_]*)\b"#, in: quoted))
            }
        }
        var parts: [String] = []
        for name in names.subtracting(standard).sorted() {
            let pattern = #"^\s*(?:(?:public|internal|private|fileprivate|final|indirect)\s+)*(?:struct|enum|class|actor|protocol|extension)\s+"#
                + NSRegularExpression.escapedPattern(for: name) + #"\b"#
            for (path, text) in sources.sorted(by: { $0.key < $1.key }) {
                let lines = text.components(separatedBy: "\n")
                for (index, line) in lines.enumerated() where line.range(of: pattern, options: .regularExpression) != nil {
                    var depth = 0, body: [String] = []
                    for next in lines[index...] {
                        body.append(next)
                        depth += next.filter { $0 == "{" }.count - next.filter { $0 == "}" }.count
                        if depth <= 0 && body.joined().contains("{") { break }
                        if body.count >= 60 { body.append("    // ..."); break }
                    }
                    parts.append("// \(path)\n" + body.joined(separator: "\n"))
                }
            }
        }
        return String(parts.joined(separator: "\n").prefix(limit))
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func isTest(_ path: String) -> Bool {
        !path.hasPrefix("<outside>") && (path.hasPrefix("Tests/") || path.contains("Tests/"))
    }
}
