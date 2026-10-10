import Foundation

/// Deterministic, structural segmentation of the original objective. Its only job is
/// to preserve every information unit (sentences, parentheticals, conditional
/// sub-clauses) so none can silently disappear from a Requirement Plan. It never
/// decides what a clause means or which file it concerns — that stays with the model.
public struct ObjectiveClause: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case sentence, parenthetical, conditional, negation, numericConstraint, explanatory
    }
    public let clauseID: String
    public let exactSourceText: String
    /// UTF-16 offsets into the original objective (NSRange-compatible).
    public let sourceRange: [Int]
    public let clauseType: Kind
    public let features: [String]
    public let mandatoryCandidate: Bool
}

public enum ObjectiveClauses {
    static let conditionalMarkers = ["なら", "場合", "とき", "たら", "ければ", "れば", "以外", "if ", "when ", "unless ", "otherwise"]
    static let negationMarkers = ["ないで", "しない", "ない", "せず", "ず、", "禁止", "not ", "never", "don't", "do not", "without", "no "]
    static let constraintMarkers = ["以上", "以下", "超え", "超える", "未満", "まで", "最大", "最小", "at most", "at least",
                                    "up to", "more than", "less than", "exceed", "≤", "≥", "<=", ">="]
    static let directiveMarkers = ["して", "させ", "ように", "追加", "返", "変え", "使っ", "使う", "許可", "拒否", "保存",
                                   "読み込", "並べ", "持たせ", "ないで", "こと", "add ", "return", "keep", "must", "should",
                                   "use ", "allow", "reject", "ensure", "make ", "do not", "don't", "store", "sort"]

    public static func segment(_ objective: String) -> [ObjectiveClause] {
        let text = objective as NSString
        var spans: [(range: NSRange, kind: ObjectiveClause.Kind?)] = []
        // Parentheticals (full/half width), including nesting, are their own clauses.
        var stack: [Int] = []
        for i in 0..<text.length {
            let c = text.character(at: i)
            if c == 0xFF08 || c == 0x28 { stack.append(i) }
            else if (c == 0xFF09 || c == 0x29), let open = stack.popLast(), i - open > 1 {
                let inner = NSRange(location: open + 1, length: i - open - 1)
                if !isCodeSyntax(inner, open: open, in: text) { spans.append((inner, .parenthetical)) }
            }
        }
        // Sentences: 。．！？!? and newlines; "." only when followed by whitespace/end
        // (keeps 1.5 and Package.swift intact). Never split inside parentheses.
        var depth = 0, start = 0
        func emitSentence(_ end: Int) {
            let r = trimmed(NSRange(location: start, length: end - start), in: text)
            if r.length > 0 { spans.append((r, nil)) }
            start = end + 1
        }
        for i in 0..<text.length {
            let c = text.character(at: i)
            if c == 0xFF08 || c == 0x28 { depth += 1 } else if c == 0xFF09 || c == 0x29 { depth = max(0, depth - 1) }
            guard depth == 0 else { continue }
            let next = i + 1 < text.length ? text.character(at: i + 1) : 0x20
            let dotEnds = c == 0x2E && (next == 0x20 || next == 0x0A)
            if [0x3002, 0xFF0E, 0xFF01, 0xFF1F, 0x21, 0x3F, 0x0A].contains(c) || dotEnds { emitSentence(i) }
        }
        if start < text.length { emitSentence(text.length) }
        // Conditional sub-clauses inside a sentence (comma-delimited) are kept separately.
        for sentence in spans where sentence.kind == nil {
            var from = sentence.range.location
            let end = NSMaxRange(sentence.range)
            var d = 0
            for i in sentence.range.location..<end {
                let c = text.character(at: i)
                if c == 0xFF08 || c == 0x28 { d += 1 } else if c == 0xFF09 || c == 0x29 { d = max(0, d - 1) }
                let last = i == end - 1
                let digitComma = c == 0x2C && i > sentence.range.location && i + 1 < end
                    && isDigit(text.character(at: i - 1)) && isDigit(text.character(at: i + 1)) // 20,000,000
                guard d == 0, ([0x3001, 0xFF0C, 0x2C, 0xFF1B, 0x3B].contains(c) && !digitComma) || last else { continue }
                let piece = trimmed(NSRange(location: from, length: (last ? i + 1 : i) - from), in: text)
                if piece.length > 0, piece != sentence.range,
                   contains(text.substring(with: piece), conditionalMarkers) {
                    spans.append((piece, .conditional))
                }
                from = i + 1
            }
        }
        let ordered = spans.sorted { $0.range.location == $1.range.location
            ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }
        var seen = Set<String>()
        var result: [ObjectiveClause] = []
        for span in ordered {
            let key = "\(span.range.location):\(span.range.length):\(span.kind?.rawValue ?? "s")"
            guard seen.insert(key).inserted else { continue }
            let exact = text.substring(with: span.range)
            var features: [String] = []
            if contains(exact, conditionalMarkers) { features.append("conditional") }
            if contains(exact, negationMarkers) { features.append("negation") }
            if exact.rangeOfCharacter(from: .decimalDigits) != nil,
               contains(exact, constraintMarkers) || exact.range(of: #"\d{2,}"#, options: .regularExpression) != nil {
                features.append("numericConstraint")
            }
            let directive = contains(exact, directiveMarkers)
            let kind: ObjectiveClause.Kind = span.kind ?? (features.contains("conditional") ? .conditional
                : features.contains("negation") ? .negation : features.contains("numericConstraint") ? .numericConstraint
                : directive ? .sentence : .explanatory)
            // Parentheticals and constraint-bearing units are never treated as optional prose.
            let mandatory = span.kind == .parenthetical || span.kind == .conditional || directive || !features.isEmpty
            result.append(.init(clauseID: "C\(result.count + 1)", exactSourceText: exact,
                sourceRange: [span.range.location, span.range.length], clauseType: kind,
                features: features, mandatoryCandidate: mandatory))
        }
        return result
    }

    /// Call/signature/type syntax such as `f(id:)` or `(String?)` is code, not a prose
    /// parenthetical: an identifier directly before "(" or a space-free code-token body.
    private static func isCodeSyntax(_ inner: NSRange, open: Int, in text: NSString) -> Bool {
        if open > 0 {
            let before = text.character(at: open - 1)
            if isDigit(before) || (before >= 0x41 && before <= 0x5A) || (before >= 0x61 && before <= 0x7A) || before == 0x5F { return true }
        }
        return text.substring(with: inner).range(of: #"^[A-Za-z0-9_?!:.<>\[\],]+$"#, options: .regularExpression) != nil
    }

    private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func contains(_ text: String, _ markers: [String]) -> Bool {
        let lower = text.lowercased()
        return markers.contains { lower.contains($0) }
    }

    private static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var lo = range.location, hi = NSMaxRange(range)
        let skip: Set<unichar> = [0x20, 0x09, 0x0A, 0x3000, 0x3001, 0x3002, 0xFF0C, 0x2C, 0xFF1B, 0x3B]
        while lo < hi, skip.contains(text.character(at: lo)) { lo += 1 }
        while hi > lo, skip.contains(text.character(at: hi - 1)) { hi -= 1 }
        return NSRange(location: lo, length: hi - lo)
    }
}
