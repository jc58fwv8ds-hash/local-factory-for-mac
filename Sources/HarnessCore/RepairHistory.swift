import Foundation

/// The errors earlier repairs of the same file ran into in this run, given with the next repair (2026-11-17: 14Translate's
/// glossary went back and forth six times: `.diacriticInsensitive` on a regular expression would not build; told where it
/// belongs, the writer took it out; the accent test then failed; shown only that, the writer put it back).
public final class RepairHistory: @unchecked Sendable {
    public static let shared = RepairHistory()
    private let lock = NSLock()
    private var seen: [String: [String]] = [:]

    public init() {}

    private var tries: [String: Int] = [:]
    private var failing: [String: Set<String>] = [:]

    /// The tests the last kept check left failing, whole (not narrowed to the files being repaired).
    public func lastFailing(root: String) -> Set<String>? {
        lock.lock(); defer { lock.unlock() }
        return failing[root]
    }

    public func setLastFailing(_ tests: Set<String>?, root: String) {
        lock.lock(); defer { lock.unlock() }
        failing[root] = tests
    }

    public func reset(root: String) {
        lock.lock(); defer { lock.unlock() }
        seen = seen.filter { !$0.key.hasPrefix(root + "|") }
        tries = tries.filter { !$0.key.hasPrefix(root + "|") }
        failing[root] = nil
    }

    /// The plan with the file repaired least in this run first, counted as tried (2026-11-18: six rounds in a row went to
    /// the translator's copy of the number reading, and the reading file's own two failures were never tried that run).
    public func leastTriedFirst(_ plan: BuildRepairPlan, root: String) -> BuildRepairPlan {
        lock.lock(); defer { lock.unlock() }
        let ordered = plan.targets.enumerated().sorted { a, b in
            let ta = tries[root + "|" + a.element.relativePath, default: 0], tb = tries[root + "|" + b.element.relativePath, default: 0]
            return ta != tb ? ta < tb : a.offset < b.offset
        }.map(\.element)
        if let first = ordered.first { tries[root + "|" + first.relativePath, default: 0] += 1 }
        return BuildRepairPlan(targets: ordered, unresolvedErrorCount: plan.unresolvedErrorCount)
    }

    /// Records this repair's instruction and returns what to add to it: the earlier, different ones for the same file.
    public func remind(root: String, path: String, instruction: String, maximumCharacters: Int = 2_500) -> String? {
        lock.lock(); defer { lock.unlock() }
        let key = root + "|" + path
        let core = Self.errors(of: instruction)
        let earlier = (seen[key] ?? []).filter { $0 != core }
        if !(seen[key] ?? []).contains(core) { seen[key, default: []].append(core) }
        guard !earlier.isEmpty else { return nil }
        return "\n\nこのファイルの前の直しでは、次のエラーも出ています。今の直しで、それをまた起こさないでください"
            + "(前の直し方に戻すと、同じエラーになります):\n" + String(earlier.suffix(2).joined(separator: "\n---\n").prefix(maximumCharacters))
    }

    /// The error lines and the reference added for them, without the file's text.
    static func errors(of instruction: String) -> String {
        let head = instruction.components(separatedBy: "\n現在のファイル全文").first ?? instruction
        return head.components(separatedBy: "\n").filter { !$0.hasPrefix("対象ファイル") && !$0.hasPrefix("変更範囲を") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
