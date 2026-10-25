import Foundation

/// Untouched-caller check (2026-10-25, false-success kind "the second place that needed the same change"): functions the
/// change left alone that use a name whose declaration it changed or added. Deterministic, no model; a rough Swift scan
/// (declarations by line pattern, bodies by brace matching outside strings and line comments).
/// Offline replay (84 recorded tests-passed runs, eval/offline/replay_caller_followup.py): one builder follow-up limited to
/// the listed functions fixed 3 of 41 false successes (c2-21 ×3) and broke none of 43 true successes; without the limit it
/// fixed 7 and broke 4 (it re-edited code the run had already changed, outside the list).
public enum UntouchedCallers {
    public struct Declaration: Equatable, Sendable {
        public let qualifiedName: String
        public let name: String
        public let text: String
        var signature: String { text.components(separatedBy: "{").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }

    public struct Hit: Equatable, Sendable {
        public let file: String
        public let declaration: Declaration
        public let uses: [String]
    }

    static let declaration = try! NSRegularExpression(pattern:
        #"^[ \t]*(?:@\w+[ \t]+)*(?:(?:public|internal|private|fileprivate|static|final|mutating|override|nonisolated|@MainActor)[ \t]+)*"#
        + #"(?:func[ \t]+([A-Za-z_]\w*)|(init)[?!]?[ \t]*\(|(?:var|let)[ \t]+([A-Za-z_]\w*)[^=\n]*\{)"#, options: [.anchorsMatchLines])
    static let type = try! NSRegularExpression(pattern: #"^[ \t]*(?:\w+[ \t]+)*(?:struct|enum|class|actor|extension)[ \t]+([A-Za-z_]\w*)"#,
                                               options: [.anchorsMatchLines])

    /// Functions, initializers and computed properties, each with the text up to the end of its brace block.
    public static func declarations(in source: String) -> [Declaration] {
        let text = source as NSString, all = NSRange(location: 0, length: text.length)
        let types = type.matches(in: source, range: all).map { ($0.range.location, text.substring(with: $0.range(at: 1))) }
        return declaration.matches(in: source, range: all).compactMap { match in
            guard let group = (1...3).first(where: { match.range(at: $0).location != NSNotFound }) else { return nil }
            let name = text.substring(with: match.range(at: group))
            let owner = types.last(where: { $0.0 < match.range.location })?.1 ?? ""
            let searchFrom = match.range.location + match.range.length - (group == 3 ? 1 : 0)
            let end = blockEnd(text, from: searchFrom)
            return Declaration(qualifiedName: "\(owner).\(name)", name: name,
                               text: text.substring(with: NSRange(location: match.range.location, length: end - match.range.location)))
        }
    }

    static func blockEnd(_ text: NSString, from start: Int) -> Int {
        let open = text.range(of: "{", options: [], range: NSRange(location: start, length: text.length - start))
        guard open.location != NSNotFound else { return text.length }
        var depth = 0, i = open.location
        while i < text.length {
            let c = text.character(at: i)
            if c == 0x2F, i + 1 < text.length, text.character(at: i + 1) == 0x2F {          // "//" to the end of the line
                let newline = text.range(of: "\n", options: [], range: NSRange(location: i, length: text.length - i))
                i = newline.location == NSNotFound ? text.length : newline.location; continue
            }
            if c == 0x22 {                                                                   // a one-line string literal
                var j = i + 1
                while j < text.length, text.character(at: j) != 0x22, text.character(at: j) != 0x0A {
                    j += text.character(at: j) == 0x5C ? 2 : 1
                }
                i = j + 1; continue
            }
            if c == 0x7B { depth += 1 }
            if c == 0x7D { depth -= 1; if depth == 0 { return i + 1 } }
            i += 1
        }
        return text.length
    }

    /// `before` / `after`: production sources (path → content) before the task and now.
    public static func find(before: [String: String], after: [String: String]) -> [Hit] {
        var original: [String: String] = [:]
        for (path, source) in before {
            for d in declarations(in: source) { original["\(path)|\(d.qualifiedName)|\(d.signature)"] = d.text }
        }
        var current: [(String, Declaration)] = []
        for (path, source) in after.sorted(by: { $0.key < $1.key }) { current += declarations(in: source).map { (path, $0) } }
        let changed = current.filter { original["\($0.0)|\($0.1.qualifiedName)|\($0.1.signature)"] != $0.1.text }
        let names = Set(changed.map(\.1.name).filter { !["init", "body", "description"].contains($0) && $0.count >= 3 })
        return current.compactMap { path, d in
            guard !changed.contains(where: { $0.0 == path && $0.1 == d }) else { return nil }
            let inner = d.text.split(separator: "{", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let uses = names.filter { $0 != d.name && inner.range(of: #"(?<![\w])"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#,
                                                                     options: .regularExpression) != nil }.sorted()
            return uses.isEmpty ? nil : Hit(file: path, declaration: d, uses: uses)
        }
    }

    /// Feedback for one follow-up proposal (the wording the offline replay measured).
    public static func feedback(_ hits: [Hit]) -> String {
        "Your change passed the tests. These functions you did not change use names whose code you changed:\n\n"
            + hits.prefix(6).map { "- \($0.file) `\($0.declaration.qualifiedName)` uses \($0.uses.joined(separator: ", ")):\n\($0.declaration.text.prefix(1200))" }
                .joined(separator: "\n\n")
            + "\nIf the request applies to any of them, change them now so the whole program follows the request. "
            + "If none needs a change, return {\"edits\":[]}."
    }

    /// An edit is kept only if the text it replaces lies inside one of the listed functions.
    public static func insideListed(_ oldText: String, file: String, hits: [Hit]) -> Bool {
        !oldText.isEmpty && hits.contains { $0.file == file && $0.declaration.text.contains(oldText) }
    }
}
