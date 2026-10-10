import Foundation

/// Phase 1 multi-stage Verifier, layer 1: deterministic symbol canonicalization and source facts.
/// Separate from any semantic judgement; a canonical name is accepted only when repository
/// declaration evidence confirms it. Production sources only.
public enum VerifierSymbols {
    public struct Resolution: Equatable, Sendable {
        public let raw: String
        public let canonical: String
        public let qualifier: String?
        public let exists: Bool
        public let reason: String
    }

    /// `Type.member` → `member`, `steps(from:)` → `steps`, `Type.method(_:)` → `method`, `` `x` `` → `x`.
    public static func canonicalForm(_ raw: String) -> (name: String, qualifier: String?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "`", with: "")
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) }
        let parts = text.split(separator: ".").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = parts.last else { return ("", nil) }
        return (last, parts.count > 1 ? parts[parts.count - 2] : nil)
    }

    /// The canonical name must be declared in production sources (or be an `init` present in the
    /// claimed file) and occur as an identifier in the claimed file; a qualifier must be a declared type.
    public static func resolve(_ raw: String, file: String, sources: [String: String]) -> Resolution {
        let (name, qualifier) = canonicalForm(raw)
        func result(_ ok: Bool, _ why: String) -> Resolution {
            .init(raw: raw, canonical: name, qualifier: qualifier, exists: ok, reason: why)
        }
        let signature = raw.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !signature.contains("(") || signature.range(of: #"^[^()]+\([^()]*\)$"#, options: .regularExpression) != nil else {
            return result(false, "malformed signature")
        }
        guard !name.isEmpty, name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            return result(false, "not an identifier")
        }
        guard let source = sources[file] else { return result(false, "file not in production sources") }
        let declared = sources.values.reduce(into: Set<String>()) { $0.formUnion(ContextRelationships.declarations($1).all) }
        let types = sources.values.reduce(into: Set<String>()) { $0.formUnion(ContextRelationships.typeDeclarations($1)) }
        if let qualifier, !types.contains(qualifier) { return result(false, "qualifier \(qualifier) is not a declared type") }
        if name == "init" {
            return source.contains("init(") ? result(true, "initializer present in file") : result(false, "no initializer in file")
        }
        guard declared.contains(name) else { return result(false, "\(name) is not declared in production sources") }
        guard ContextRelationships.identifiers(source).contains(name) else { return result(false, "\(name) does not occur in \(file)") }
        return result(true, "declared and present")
    }
}

/// Layer 2: facts that can be read off source text without understanding the requirement.
public enum VerifierFacts {
    public enum Kind: String, Codable, Sendable {
        case numericLiteral, stringLiteral, booleanLiteral, comparison, bounds, nilCheck, enumCase, branch,
             invocation, declaration, returnPath, failurePath
    }
    public struct Fact: Codable, Equatable, Sendable {
        public let kind: Kind
        public let line: Int
        public let text: String
    }
    public struct Scope: Equatable, Sendable {
        public let name: String
        public let lines: ClosedRange<Int>
    }

    static let patterns: [(Kind, String)] = [
        (.numericLiteral, #"(?<![A-Za-z_0-9.])\d[\d_]*(?:\.\d+)?(?![A-Za-z_0-9])"#),
        (.stringLiteral, #""(?:\\.|[^"\\])*""#),
        (.booleanLiteral, #"\b(?:true|false)\b"#),
        (.comparison, #"(?:==|!=|<=|>=|(?<![-=<>])<(?![<=])|(?<![-=<>])>(?![>=]))"#),
        (.bounds, #"\.\.\.|\.\.<|\bmin\(|\bmax\(|\bclamp"#),
        (.nilCheck, #"==\s*nil|!=\s*nil|\bguard\s+let\b|\bif\s+let\b|\?\?|\?\."#),
        (.enumCase, #"(?<![A-Za-z0-9_])\.[a-z][A-Za-z0-9_]*\b|\bcase\s+[a-z][A-Za-z0-9_]*"#),
        (.branch, #"\b(?:if|guard|switch|else|while)\b|\?\s*[^:]+:"#),
        (.invocation, #"\b[A-Za-z_][A-Za-z0-9_]*\s*\("#),
        (.declaration, #"\b(?:struct|class|actor|protocol|enum|func|var|let|init|case)\b"#),
        (.returnPath, #"\breturn\b"#),
        (.failurePath, #"\bthrow\b|\bfatalError\b|\bpreconditionFailure\b"#)
    ]

    /// One fact per matched kind per line; comments are ignored.
    public static func extract(_ source: String) -> [Fact] {
        var facts: [Fact] = []
        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = raw.components(separatedBy: "//").first ?? raw
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            for (kind, pattern) in patterns where line.range(of: pattern, options: .regularExpression) != nil {
                facts.append(.init(kind: kind, line: index, text: line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return facts
    }

    /// Declaration scopes by brace matching (stored properties without a body span one line).
    public static func scopes(_ source: String) -> [Scope] {
        let lines = source.components(separatedBy: "\n")
        let declaration = #"\b(?:struct|class|actor|protocol|enum|func|var|let|init|subscript)\b\s*([A-Za-z_][A-Za-z0-9_]*)?"#
        var result: [Scope] = []
        for (index, line) in lines.enumerated() {
            guard let range = line.range(of: declaration, options: .regularExpression) else { continue }
            let match = String(line[range])
            let name = match.hasPrefix("init") ? "init"
                : match.split(whereSeparator: { $0 == " " }).dropFirst().first.map(String.init) ?? ""
            guard !name.isEmpty else { continue }
            var depth = 0, parens = 0, opened = false, end = index
            scan: for i in index..<lines.count {
                // A declaration without a body ends at its own line unless its signature is still open.
                if !opened && i > index && parens <= 0 { end = index; break }
                for character in lines[i] {
                    if character == "(" { parens += 1 }
                    if character == ")" { parens -= 1 }
                    if character == "{" { depth += 1; opened = true }
                    if character == "}" { depth -= 1 }
                    if opened && depth <= 0 { end = i; break scan }
                }
                end = i
            }
            result.append(.init(name: name, lines: index...max(index, end)))
        }
        return result
    }
}
