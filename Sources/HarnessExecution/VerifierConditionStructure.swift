import Foundation

/// Phase 6: deterministic condition structure extracted from Swift tokens (not a compiler).
/// Boolean trees are built from `&&`, `||`, prefix `!`, parentheses and `if`-condition commas, with
/// comparison atoms (`<`, `<=`, `>`, `>=`, `==`, `!=`). Anything that does not parse cleanly is
/// reported as unparsed, never guessed.
public enum VerifierConditionStructure {
    typealias Token = VerifierSourceTokens.Token

    public struct Atom: Codable, Equatable, Sendable {
        public let text: String
        public let lhs: String?
        public let op: String?
        public let rhs: String?
        public let line: Int
    }

    public indirect enum Tree: Codable, Equatable, Sendable {
        case and([Tree]), or([Tree]), not(Tree), atom(Atom)
    }

    public enum Kind: String, Codable, Sendable { case ifCondition, guardCondition, whileCondition, booleanReturn, ternary, switchCase }

    public struct Site: Codable, Equatable, Sendable {
        public let node: String
        public let kind: Kind
        public let tree: Tree
        /// The result this site produces when its condition holds: first `return` expression of the
        /// then-block, the ternary's true arm, or "true" for a boolean return. nil = no direct result.
        public let result: String?
        /// Every result this function returns anywhere (to check exclusivity).
        public let lines: ClosedRange<Int>
        /// True if an earlier statement in the same body can exit (return/throw/guard-else) before this site.
        public let precededByExit: Bool
        public let operatorText: String
    }

    struct Extraction: Sendable {
        let sites: [Site]
        let returns: [(expression: String, line: Int, guardedBy: [Tree])]
        let unparsed: Int
    }

    static func text(_ tokens: ArraySlice<Token>) -> String {
        var out = ""
        var previous: Token? = nil
        for t in tokens {
            if let p = previous, p.end != t.offset { out += " " }
            out += t.text; previous = t
        }
        return out
    }

    /// Operator runs: adjacent single-character tokens (e.g. `&` `&` → `&&`, `>` `=` → `>=`).
    static func op(_ tokens: [Token], _ i: Int) -> (String, Int)? {
        guard i < tokens.count else { return nil }
        let t = tokens[i].text
        let next = i + 1 < tokens.count && tokens[i + 1].offset == tokens[i].end ? tokens[i + 1].text : nil
        switch (t, next) {
        case ("&", "&"): return ("&&", 2)
        case ("|", "|"): return ("||", 2)
        case ("=", "="): return ("==", 2)
        case ("!", "="): return ("!=", 2)
        case ("<", "="): return ("<=", 2)
        case (">", "="): return (">=", 2)
        case ("<", _): return ("<", 1)
        case (">", _): return (">", 1)
        default: return nil
        }
    }

    /// A ternary `?` is separated by whitespace from the previous token; optional chaining/unwrapping is not.
    static func isTernary(_ tokens: [Token], _ i: Int) -> Bool {
        tokens[i].text == "?" && i > 0 && tokens[i - 1].end != tokens[i].offset
    }

    /// Parses a condition token slice. Returns nil if brackets are unbalanced or it contains a
    /// construct we do not model (closures, `try`, `await`, assignments, ternaries inside conditions).
    static func parse(_ tokens: [Token]) -> Tree? {
        guard !tokens.isEmpty, !tokens.contains(where: { ["{", "}", "try", "await"].contains($0.text) }),
              !tokens.indices.contains(where: { isTernary(tokens, $0) }) else { return nil }
        var depth = 0
        for t in tokens {
            if ["(", "["].contains(t.text) { depth += 1 } else if [")", "]"].contains(t.text) { depth -= 1 }
            if depth < 0 { return nil }
        }
        guard depth == 0 else { return nil }
        // Split at top-level operator of the given kind.
        func split(_ ts: [Token], _ separator: String) -> [[Token]] {
            var parts: [[Token]] = [[]], d = 0, i = 0
            while i < ts.count {
                if ["(", "["].contains(ts[i].text) { d += 1 } else if [")", "]"].contains(ts[i].text) { d -= 1 }
                if d == 0, let (o, n) = op(ts, i), o == separator { parts.append([]); i += n; continue }
                if d == 0, separator == "&&", ts[i].text == "," { parts.append([]); i += 1; continue }
                parts[parts.count - 1].append(ts[i]); i += 1
            }
            return parts
        }
        func build(_ ts: [Token]) -> Tree? {
            guard !ts.isEmpty else { return nil }
            let ors = split(ts, "||")
            if ors.count > 1 { let kids = ors.map(build); return kids.contains(where: { $0 == nil }) ? nil : .or(kids.map { $0! }) }
            let ands = split(ts, "&&")
            if ands.count > 1 { let kids = ands.map(build); return kids.contains(where: { $0 == nil }) ? nil : .and(kids.map { $0! }) }
            if ts[0].text == "!", ts.count > 1, ts[1].offset == ts[0].end, ts[1].text != "=" {
                return build(Array(ts.dropFirst())).map { .not($0) }
            }
            if ts.first?.text == "(", ts.last?.text == ")" {
                // Strip one pair only if it encloses everything.
                var d = 0, encloses = true
                for (k, t) in ts.enumerated() {
                    if t.text == "(" { d += 1 } else if t.text == ")" { d -= 1 }
                    if d == 0 && k < ts.count - 1 { encloses = false; break }
                }
                if encloses { return build(Array(ts.dropFirst().dropLast())) }
            }
            if ts.contains(where: { $0.text == "=" }) && !ts.indices.contains(where: { op(ts, $0).map { ["==", "!=", "<=", ">="].contains($0.0) } == true }) {
                // `let x = …` bindings are atoms, plain assignments are not conditions.
                guard ts.first?.text == "let" || ts.first?.text == "var" || ts.first?.text == "case" else { return nil }
            }
            var d = 0
            for i in ts.indices {
                if ["(", "["].contains(ts[i].text) { d += 1 } else if [")", "]"].contains(ts[i].text) { d -= 1 }
                if d == 0, let (o, n) = op(ts, i), ["<", "<=", ">", ">=", "==", "!="].contains(o),
                   !(o == "<" && i > 0 && ts[i - 1].text == "-") {
                    return .atom(.init(text: text(ts[...]), lhs: text(ts[..<i]), op: o, rhs: text(ts[(i + n)...]), line: ts[0].line))
                }
            }
            return .atom(.init(text: text(ts[...]), lhs: nil, op: nil, rhs: nil, line: ts[0].line))
        }
        return build(tokens)
    }

    /// Extracts condition sites from one declaration body.
    static func extract(_ tokens: [VerifierSourceTokens.Token], node: String) -> Extraction {
        guard let pairs = try? VerifierSourceTokens.pairs(tokens) else { return .init(sites: [], returns: [], unparsed: 1) }
        var sites: [Site] = [], returns: [(String, Int, [Tree])] = [], unparsed = 0
        var exitSeen = false
        var guards: [(ClosedRange<Int>, Tree)] = []   // token ranges of then-blocks with their conditions
        func firstReturn(_ range: ClosedRange<Int>) -> String? {
            guard let r = tokens[range].firstIndex(where: { $0.text == "return" }) else { return nil }
            var end = r + 1
            while end <= range.upperBound, tokens[end].line == tokens[r].line, tokens[end].text != "}" { end += 1 }
            return end > r + 1 ? text(tokens[(r + 1)..<end]) : nil
        }
        var i = 0
        while i < tokens.count {
            let t = tokens[i].text
            if ["if", "guard", "while"].contains(t) {
                let stop = t == "guard" ? "else" : "{"
                guard let end = tokens[(i + 1)...].firstIndex(where: { $0.text == stop }) else { unparsed += 1; i += 1; continue }
                let conditionTokens = Array(tokens[(i + 1)..<end])
                let open = t == "guard" ? tokens[end...].firstIndex(where: { $0.text == "{" }) : end
                if let tree = parse(conditionTokens), let open, let close = pairs[open] {
                    let body = (open + 1)...max(open + 1, close - 1)
                    let result = close > open + 1 ? firstReturn(body) : nil
                    let ops = conditionTokens.indices.compactMap { op(conditionTokens, $0)?.0 }
                    sites.append(.init(node: node, kind: t == "if" ? .ifCondition : t == "guard" ? .guardCondition : .whileCondition,
                                       tree: t == "guard" ? .not(tree) : tree, result: result,
                                       lines: tokens[i].line...tokens[close].line, precededByExit: exitSeen, operatorText: ops.joined(separator: " ")))
                    if t == "if", close > open + 1 { guards.append((body, tree)) }
                    if t == "guard" { exitSeen = true }
                } else { unparsed += 1 }
                i = end + 1; continue
            }
            if t == "return" || t == "throw" {
                var end = i + 1
                while end < tokens.count, tokens[end].line == tokens[i].line, tokens[end].text != "}" { end += 1 }
                let expression = Array(tokens[(i + 1)..<end])
                if t == "return", !expression.isEmpty {
                    let enclosing = guards.filter { $0.0.contains(i) }.map(\.1)
                    returns.append((text(expression[...]), tokens[i].line, enclosing))
                    if let q = expression.indices.first(where: { isTernary(expression, $0) }),
                       let colon = expression[q...].firstIndex(where: { $0.text == ":" }), q > 0,
                       let tree = parse(Array(expression[..<q])) {
                        sites.append(.init(node: node, kind: .ternary, tree: tree, result: text(expression[(q + 1)..<colon]),
                                           lines: tokens[i].line...tokens[i].line, precededByExit: exitSeen, operatorText: "?:"))
                    } else if expression.indices.contains(where: { op(expression, $0) != nil }), let tree = parse(expression) {
                        let ops = expression.indices.compactMap { op(expression, $0)?.0 }
                        sites.append(.init(node: node, kind: .booleanReturn, tree: tree, result: "true",
                                           lines: tokens[i].line...tokens[i].line, precededByExit: exitSeen, operatorText: ops.joined(separator: " ")))
                    }
                }
                // A return nested in a block is an exit for everything after that block.
                exitSeen = true
                i = end; continue
            }
            i += 1
        }
        return .init(sites: sites, returns: returns, unparsed: unparsed)
    }
}
