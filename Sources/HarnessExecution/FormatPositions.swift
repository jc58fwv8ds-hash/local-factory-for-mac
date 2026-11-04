import Foundation

/// Character positions of the fixed formats a request quotes (2026-11-01). In 6 of the 21 Personal Memory tasks whose
/// result the supervisor had to fix, the model counted the positions of a line head such as 「[数字2桁:数字2桁] 」 wrong
/// (the closing bracket at 5 instead of 6, the minutes from 3 instead of 4). The positions are worked out here, without a
/// model, and shown under the request.
public enum FormatPositions {
    static let quoted = try! NSRegularExpression(pattern: #"「([^」\n]{2,30})」|"([^"\n]{2,30})""#)
    static let placeholder = try! NSRegularExpression(pattern: #"数字(\d)桁|(?<![A-Za-z])(?:yyyy|HH|MM|dd|mm|ss)(?![A-Za-z])"#)

    /// One line per quoted format that has a digit placeholder and at least one fixed character; nil when there is none.
    public static func note(_ objective: String) -> String? {
        let text = objective as NSString
        var lines: [String] = [], seen = Set<String>()
        for match in quoted.matches(in: objective, range: NSRange(location: 0, length: text.length)) {
            let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let format = text.substring(with: range)
            guard !seen.contains(format), let line = positions(format) else { continue }
            seen.insert(format)
            lines.append(line)
        }
        guard !lines.isEmpty else { return nil }
        return "Character positions (0-based) of the fixed formats in the request:\n" + lines.map { "- " + $0 }.joined(separator: "\n")
    }

    /// 「[数字2桁:数字2桁] 」 → "「[数字2桁:数字2桁] 」 is 8 characters: 0 "[", 1-2 digits, 3 ":", 4-5 digits, 6 "]", 7 space."
    /// The count stops at the first letter that is not a placeholder (「[HH:mm] 文」: 文 stands for the text, any length).
    static func positions(_ format: String) -> String? {
        let ns = format as NSString
        var parts: [String] = [], index = 0, cursor = 0, digits = 0, fixed = 0, rest = false
        func literal(_ s: String) {
            for c in s where !rest {
                if c.isLetter { rest = true; return }
                parts.append("\(index) " + (c == " " ? "space" : c == "　" ? "full-width space" : "\"\(c)\""))
                index += 1; fixed += 1
            }
        }
        for match in placeholder.matches(in: format, range: NSRange(location: 0, length: ns.length)) where !rest {
            literal(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            if rest { break }
            let count = match.range(at: 1).location != NSNotFound ? Int(ns.substring(with: match.range(at: 1))) ?? 1 : match.range.length
            parts.append(count == 1 ? "\(index) digit" : "\(index)-\(index + count - 1) digits")
            index += count; digits += 1
            cursor = match.range.location + match.range.length
        }
        if !rest { literal(ns.substring(from: cursor)) }
        guard digits > 0, fixed > 0 else { return nil }
        return rest ? "「\(format)」 starts with \(index) fixed characters: " + parts.joined(separator: ", ") + ", then the rest."
            : "「\(format)」 is \(index) characters: " + parts.joined(separator: ", ") + "."
    }
}
