import Foundation

/// Narrow lexical front-end for evidence discovery, not a Swift compiler. Unsupported
/// lexical constructs invalidate the file instead of being approximated as identifiers.
enum VerifierSourceTokens {
    struct Token: Equatable, Sendable {
        let text: String
        let line: Int
        let offset: Int
        let end: Int
        var identifier: Bool {
            text.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
        }
    }
    enum Failure: Error { case unsupported, malformed, overBound }

    static func scan(_ source: String) throws -> [Token] {
        let bytes = Array(source.utf8)
        guard bytes.count <= 128_000 else { throw Failure.overBound }
        var index = 0, line = 0
        var tokens: [Token] = []
        func isWord(_ c: UInt8) -> Bool {
            (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 95
        }
        func next(_ distance: Int = 1) -> UInt8? {
            index + distance < bytes.count ? bytes[index + distance] : nil
        }
        while index < bytes.count {
            let c = bytes[index]
            if c == 10 { line += 1; index += 1; continue }
            if c == 32 || c == 9 || c == 13 { index += 1; continue }
            if c == 47, next() == 47 {
                while index < bytes.count && bytes[index] != 10 { index += 1 }
                continue
            }
            if c == 47, next() == 42 {
                var depth = 1; index += 2
                while index < bytes.count && depth > 0 {
                    if bytes[index] == 47, next() == 42 { depth += 1; index += 2 }
                    else if bytes[index] == 42, next() == 47 { depth -= 1; index += 2 }
                    else { if bytes[index] == 10 { line += 1 }; index += 1 }
                }
                guard depth == 0 else { throw Failure.malformed }
                continue
            }
            // Raw strings, conditional compilation, macros, escaped and Unicode identifiers
            // require a compiler-backed resolver; do not silently misread them.
            if c == 35 || c == 96 || c >= 128 { throw Failure.unsupported }
            // A plain attribute (`@name` or `@name(...)` on one line) does not change which
            // declaration a name refers to; it is skipped. Anything else stays unsupported.
            if c == 64 {
                index += 1
                guard index < bytes.count, isWord(bytes[index]), !(48...57).contains(bytes[index]) else { throw Failure.unsupported }
                while index < bytes.count && isWord(bytes[index]) { index += 1 }
                if index < bytes.count && bytes[index] == 40 {
                    var depth = 0
                    repeat {
                        guard index < bytes.count, bytes[index] != 10, bytes[index] != 34 else { throw Failure.unsupported }
                        if bytes[index] == 40 { depth += 1 } else if bytes[index] == 41 { depth -= 1 }
                        index += 1
                    } while depth > 0
                }
                continue
            }
            let start = index, startLine = line
            if c == 34 {
                // String contents, including interpolations, are one opaque literal token: nothing
                // inside a string can create a relation. Interpolations may only be followed, never
                // nested with further string literals (those need a real parser).
                let multiline = next() == 34 && next(2) == 34
                index += multiline ? 3 : 1
                var closed = false
                while index < bytes.count {
                    if bytes[index] == 10 {
                        guard multiline else { throw Failure.malformed }
                        line += 1; index += 1
                    } else if bytes[index] == 92 {
                        if next() == 40 {
                            var depth = 1; index += 2
                            while index < bytes.count && depth > 0 {
                                guard bytes[index] != 34, bytes[index] != 10 else { throw Failure.unsupported }
                                if bytes[index] == 40 { depth += 1 } else if bytes[index] == 41 { depth -= 1 }
                                index += 1
                            }
                            guard depth == 0 else { throw Failure.malformed }
                        } else { index += 2 }
                    } else if bytes[index] == 34 {
                        if !multiline { index += 1; closed = true; break }
                        if next() == 34 && next(2) == 34 { index += 3; closed = true; break }
                        index += 1
                    } else { index += 1 }
                }
                guard closed else { throw Failure.malformed }
                tokens.append(.init(text: "<literal>", line: startLine, offset: start, end: index))
            } else if (48...57).contains(c) {
                // Numeric literal kept whole (including a decimal part) so values can be compared.
                index += 1
                while index < bytes.count && (isWord(bytes[index]) || (bytes[index] == 46 && next().map { (48...57).contains($0) } == true)) { index += 1 }
                tokens.append(.init(text: String(decoding: bytes[start..<index], as: UTF8.self),
                                    line: startLine, offset: start, end: index))
            } else if isWord(c) {
                index += 1
                while index < bytes.count && isWord(bytes[index]) { index += 1 }
                tokens.append(.init(text: String(decoding: bytes[start..<index], as: UTF8.self),
                                    line: startLine, offset: start, end: index))
            } else {
                index += 1
                tokens.append(.init(text: String(UnicodeScalar(c)), line: startLine, offset: start, end: index))
            }
            guard tokens.count <= 24_000 else { throw Failure.overBound }
        }
        return tokens
    }

    static func pairs(_ tokens: [Token]) throws -> [Int: Int] {
        let closing = [")": "(", "]": "[", "}": "{"]
        var stack: [Int] = [], result: [Int: Int] = [:]
        for i in tokens.indices {
            let text = tokens[i].text
            if ["(", "[", "{"].contains(text) { stack.append(i) }
            else if let opening = closing[text] {
                guard let start = stack.popLast(), tokens[start].text == opening else { throw Failure.malformed }
                result[start] = i
            }
        }
        guard stack.isEmpty else { throw Failure.malformed }
        return result
    }
}
