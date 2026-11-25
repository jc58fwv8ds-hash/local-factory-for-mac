import CryptoKit
import Foundation

/// The changes already proposed for the very same request, so it is not sent again unchanged (2026-11-25, the user: 「やり直
/// しを、ただの繰り返しにしない」). On 2026-11-18, 46 file requests (141 of 1,000 minutes) were byte-for-byte repeats of an
/// earlier one: the change had failed and been undone, the file and the error were the same, and RepairHistory adds only
/// errors that differ. A repeat now carries the lines the earlier answer changed and that they did not work.
public final class TriedEdits: @unchecked Sendable {
    public static let shared = TriedEdits()
    private let lock = NSLock()
    private var tried: [String: [String]] = [:]

    public init() {}

    public static func key(path: String, content: String, instruction: String) -> String {
        SHA256.hash(data: Data((path + "\u{0}" + content + "\u{0}" + instruction).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What to add to a request already answered with these changes; nil the first time.
    public func note(for key: String, maximumCharacters: Int = 2_000) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let earlier = tried[key], !earlier.isEmpty else { return nil }
        return "\n\nこの依頼には前にも次の直しを返しましたが、通らず元に戻されました。同じ直しは返さず、別の直し方を考えてください"
            + "(- は消した行、+ は足した行):\n" + String(earlier.suffix(2).joined(separator: "\n---\n").prefix(maximumCharacters))
    }

    /// Remembers the change proposed for the request (as the lines taken out and put in).
    public func record(_ key: String, before: String, after: String) {
        let change = Self.changedLines(before: before, after: after)
        guard !change.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if tried[key]?.contains(change) != true { tried[key, default: []].append(change) }
    }

    public func reset() { lock.lock(); tried = [:]; lock.unlock() }

    static func changedLines(before: String, after: String, maximumLines: Int = 40) -> String {
        let difference = after.components(separatedBy: "\n").difference(from: before.components(separatedBy: "\n"))
        var lines: [String] = []
        for change in difference {
            switch change {
            case let .remove(_, line, _): lines.append("- " + line)
            case let .insert(_, line, _): lines.append("+ " + line)
            }
        }
        if lines.count > maximumLines { lines = Array(lines.prefix(maximumLines)) + ["(ほか \(lines.count - maximumLines) 行)"] }
        return lines.joined(separator: "\n")
    }
}
