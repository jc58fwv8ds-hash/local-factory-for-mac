import Foundation

/// Leftover-clone check (plan 0005, false-success kind B "a place the change missed"): code the change replaced that still
/// exists, as the same run of tokens, in a production file the change did not touch. Deterministic, no model.
/// Offline (120 tests-passed runs): flagged every recorded miss of this kind (c2-13 ×1, c2-14 ×2) and 7 of 99 true successes.
public enum LeftoverClones {
    public static let minimumTokens = 12

    public struct Hit: Equatable, Sendable {
        public let file: String
        public let line: Int
        public let text: String
        public let replacedIn: String
    }

    /// `changes`: path → (content before the task, content now). `sources`: every production source now (path → content).
    public static func find(changes: [String: (before: String, after: String)], sources: [String: String],
                            minimumTokens: Int = minimumTokens) -> [Hit] {
        var hits: [Hit] = []
        for (path, change) in changes.sorted(by: { $0.key < $1.key }) {
            let after = Set(change.after.components(separatedBy: "\n"))
            for line in change.before.components(separatedBy: "\n") where !after.contains(line) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                let toks = tokens(trimmed)
                guard toks.count >= minimumTokens else { continue }
                let windows = Set((0...(toks.count - minimumTokens)).map { " " + toks[$0..<$0 + minimumTokens].joined(separator: " ") + " " })
                for (other, text) in sources.sorted(by: { $0.key < $1.key }) where changes[other] == nil {
                    for (index, candidate) in text.components(separatedBy: "\n").enumerated() {
                        let joined = " " + tokens(candidate).joined(separator: " ") + " "
                        if windows.contains(where: joined.contains),
                           !hits.contains(where: { $0.file == other && $0.line == index + 1 }) {
                            hits.append(.init(file: other, line: index + 1,
                                              text: String(candidate.trimmingCharacters(in: .whitespaces).prefix(160)), replacedIn: path))
                        }
                    }
                }
            }
        }
        return hits
    }

    /// Feedback for one follow-up proposal: where the replaced code still is; the model decides whether the request applies.
    public static func feedback(_ hits: [Hit]) -> String {
        "Your change passed the tests. The code you replaced still exists unchanged in other files:\n"
            + hits.prefix(8).map { "- \($0.file) line \($0.line): `\($0.text)` (you replaced the same code in \($0.replacedIn))" }
                .joined(separator: "\n")
            + "\nIf the request applies to these places too, change them the same way now. If it does not, return {\"edits\":[]}."
    }

    static func tokens(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*|\d+|\S"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
