import Foundation

/// Known Swift pitfalls in the code a change added (2026-11-01, false-success kind "passes the tests, wrong outside them").
/// From the supervisor's fixes to 40 Personal Memory tasks: a DateFormatter whose time zone is never set formats in this
/// Mac's zone instead of the calendar's (pm-clean-02, pm-day-02, pm-day-05, pm-day-07; two of them passed the hidden tests
/// too), and Dictionary(uniqueKeysWithValues:) traps on a repeated key (pm-day-01). Deterministic, no model: only functions
/// the change added or changed are read (UntouchedCallers.declarations), and a pattern counts only when the function did
/// not have it before. Offline (81 recorded tests-passed runs, eval/offline/pitfalls.py): 4 hits, all real errors.
public enum SwiftPitfalls {
    public enum Kind: String, Sendable, CaseIterable {
        case formatterTimeZone
        case uniqueKeys

        /// What to tell the builder (the wording the offline replay measured).
        public var advice: String {
            switch self {
            case .formatterTimeZone:
                "creates a DateFormatter but never sets its timeZone, so it formats in this Mac's time zone. If the request "
                    + "names a calendar or time zone for the date, set the formatter's timeZone (and calendar) to it, and its locale to "
                    + "Locale(identifier: \"en_US_POSIX\") for a fixed format."
            case .uniqueKeys:
                "uses Dictionary(uniqueKeysWithValues:), which crashes when a key repeats. If keys can repeat, use "
                    + "Dictionary(_:uniquingKeysWith:) and keep the value the request asks for."
            }
        }
    }

    public struct Hit: Equatable, Sendable {
        public let file: String
        public let declaration: UntouchedCallers.Declaration
        public let kinds: [Kind]
    }

    static let formatter = try! NSRegularExpression(pattern: #"(?<![\w])DateFormatter\(\)"#)

    /// The pitfalls in one function's text.
    public static func kinds(in text: String) -> [Kind] {
        var found: [Kind] = []
        if formatter.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil && !text.contains("timeZone") {
            found.append(.formatterTimeZone)
        }
        if text.contains("Dictionary(uniqueKeysWithValues:") { found.append(.uniqueKeys) }
        return found
    }

    /// `before` / `after`: production sources (path → content) before the task and now.
    public static func find(before: [String: String], after: [String: String]) -> [Hit] {
        var original: [String: String] = [:]
        for (path, source) in before {
            for d in UntouchedCallers.declarations(in: source) { original["\(path)|\(d.qualifiedName)"] = d.text }
        }
        var hits: [Hit] = []
        for (path, source) in after.sorted(by: { $0.key < $1.key }) {
            for d in UntouchedCallers.declarations(in: source) {
                let old = original["\(path)|\(d.qualifiedName)"]
                guard old != d.text else { continue }
                let had = old.map(kinds(in:)) ?? []
                let new = kinds(in: d.text).filter { !had.contains($0) }
                if !new.isEmpty { hits.append(Hit(file: path, declaration: d, kinds: new)) }
            }
        }
        return hits
    }

    /// Feedback for one follow-up proposal (the wording the offline replay measured).
    public static func feedback(_ hits: [Hit]) -> String {
        "Your change passed the tests. Check these places in the code you wrote:\n\n"
            + hits.prefix(6).map { "- \($0.file) `\($0.declaration.qualifiedName)` " + $0.kinds.map(\.advice).joined(separator: " ")
                + "\n\($0.declaration.text.prefix(1200))" }.joined(separator: "\n\n")
            + "\nChange only what is needed. If none needs a change, return {\"edits\":[]}."
    }
}
