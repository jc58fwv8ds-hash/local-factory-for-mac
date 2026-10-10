import Foundation

/// A deterministic, in-memory repository index. It stores names and bounded
/// signatures, never model-generated aliases or task-specific vocabulary.
public struct RepositorySymbolIndex: Sendable {
    public enum Kind: String, Codable, Sendable { case file, type, protocolType, enumeration, function, method, property, enumerationCase, test, reference, importName }
    public struct Symbol: Codable, Equatable, Sendable {
        public let file: String
        public let name: String
        public let kind: Kind
        public let signature: String
        public let subtokens: [String]
    }
    public struct Match: Codable, Equatable, Sendable {
        public let file: String
        public let symbol: String
        public let clauseID: String
        public let clauseText: String
        public let evidenceType: String
        public let score: Int
        public let reason: String
    }
    public let symbols: [Symbol]
    private let sources: [String: String]

    public init(sources: [String: String]) {
        self.sources = sources
        self.symbols = sources.keys.sorted().flatMap { Self.index(path: $0, source: sources[$0] ?? "") }
    }

    public func retrieve(clauses: [ObjectiveClause], searchTerms: [String] = [], maximumFiles: Int = 5) -> [Match] {
        let extra = searchTerms.flatMap(Self.subtokens).filter { $0.count >= 2 }
        var best: [String: Match] = [:]
        let searchedClauses = clauses.contains(where: \.mandatoryCandidate) ? clauses.filter(\.mandatoryCandidate) : clauses
        for clause in searchedClauses {
            let exact = ContextRelationships.identifiers(clause.exactSourceText)
            let terms = Set(exact.flatMap(Self.subtokens) + extra)
            for symbol in symbols {
                var score = 0, evidence = "", reason = ""
                if exact.contains(symbol.name) {
                    if symbol.kind == .reference {
                        score = 78; evidence = "referenced_symbol"; reason = "objective identifier is referenced in file"
                    } else {
                        score = 100; evidence = "exact_identifier_declaration"; reason = "objective identifier exactly matches declaration"
                    }
                } else {
                    let overlap = Set(symbol.subtokens).intersection(terms)
                    if !overlap.isEmpty {
                        score = min(72, overlap.count * 24 + (symbol.kind == .reference ? 0 : 12))
                        evidence = "identifier_subtoken"; reason = "identifier subtokens: \(overlap.sorted().joined(separator: ", "))"
                    }
                }
                if symbol.kind == .test && score > 0 { score += 8; evidence = "test_relation" }
                guard score > 0 else { continue }
                let match = Match(file: symbol.file, symbol: symbol.name, clauseID: clause.clauseID,
                                  clauseText: clause.exactSourceText, evidenceType: evidence,
                                  score: score, reason: reason)
                if let old = best[symbol.file], old.score > score || old.score == score && old.symbol <= symbol.name { continue }
                best[symbol.file] = match
            }
        }
        return best.values.sorted {
            $0.score == $1.score ? ($0.file == $1.file ? $0.symbol < $1.symbol : $0.file < $1.file) : $0.score > $1.score
        }.prefix(maximumFiles).map { $0 }
    }

    public func contains(file: String, symbol: String) -> Bool {
        symbols.contains { $0.file == file && $0.name == symbol }
    }

    public func hasRelation(file: String, to otherFiles: [String]) -> Bool {
        let own = Set(symbols.filter { $0.file == file && $0.kind != .reference }.map(\.name))
        let other = Set(symbols.filter { otherFiles.contains($0.file) }.map(\.name))
        return !own.intersection(other).isEmpty || !Set(ContextRelationships.identifiers(sources[file] ?? "")).intersection(other).isEmpty
    }

    public static func subtokens(_ identifier: String) -> [String] {
        let dotted = identifier.replacingOccurrences(of: ".", with: "_")
        let camel = dotted.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1_$2", options: .regularExpression)
        return camel.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.lowercased() }.filter { !$0.isEmpty }
    }

    private static func index(path: String, source: String) -> [Symbol] {
        var result: [Symbol] = []
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        result.append(.init(file: path, name: stem, kind: .file, signature: path, subtokens: subtokens(stem)))
        let ns = source as NSString
        if let imports = try? NSRegularExpression(pattern: #"(?m)^\s*import\s+([A-Za-z_][A-Za-z0-9_.]*)"#) {
            for match in imports.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 1))
                result.append(.init(file: path, name: name, kind: .importName,
                                    signature: ns.substring(with: match.range), subtokens: subtokens(name)))
            }
        }
        let declaration = #"\b(?:public\s+|internal\s+|private\s+|fileprivate\s+|static\s+|class\s+|mutating\s+)*(struct|class|actor|protocol|enum|typealias|func|var|let|case)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        if let regex = try? NSRegularExpression(pattern: declaration) {
            for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let keyword = ns.substring(with: match.range(at: 1)), name = ns.substring(with: match.range(at: 2))
                let line = ns.lineRange(for: match.range)
                let signature = String(ns.substring(with: line).prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = ns.substring(to: match.range.location)
                let nesting = prefix.reduce(into: 0) { depth, character in
                    if character == "{" { depth += 1 }; if character == "}" { depth -= 1 }
                }
                let kind: Kind = switch keyword {
                case "struct", "class", "actor", "typealias": .type
                case "protocol": .protocolType
                case "enum": .enumeration
                case "func": nesting > 0 ? .method : .function
                case "var", "let": .property
                case "case": .enumerationCase
                default: .reference
                }
                result.append(.init(file: path, name: name, kind: kind, signature: signature, subtokens: subtokens(name)))
            }
        }
        if let cases = try? NSRegularExpression(pattern: #"(?m)\bcase\s+([^\n{}]+)"#) {
            for match in cases.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let list = ns.substring(with: match.range(at: 1))
                for item in list.split(separator: ",") {
                    let name = item.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == "(" || $0 == "=" || $0 == " " }).first.map(String.init) ?? ""
                    if name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
                       !result.contains(where: { $0.kind == .enumerationCase && $0.name == name }) {
                        result.append(.init(file: path, name: name, kind: .enumerationCase,
                                            signature: "case " + list, subtokens: subtokens(name)))
                    }
                }
            }
        }
        for name in ContextRelationships.identifiers(source).sorted() where !result.contains(where: { $0.name == name }) {
            result.append(.init(file: path, name: name, kind: .reference, signature: name, subtokens: subtokens(name)))
        }
        if path.lowercased().contains("tests/") || path.lowercased().contains("uitests/") {
            result = result.map { .init(file: $0.file, name: $0.name, kind: $0.kind == .file ? .test : $0.kind,
                                         signature: $0.signature, subtokens: $0.subtokens) }
        }
        return result.sorted { $0.name == $1.name ? $0.kind.rawValue < $1.kind.rawValue : $0.name < $1.name }
    }
}
