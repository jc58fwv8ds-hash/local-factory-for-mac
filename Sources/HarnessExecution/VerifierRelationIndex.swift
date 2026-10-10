import Foundation

/// Syntactic evidence discovery, NOT semantic verification. Indexes members of nongeneric
/// structs/enums (static and instance), protocol and type declarations, and only relations whose
/// target is uniquely determined: `Type.member`, `self.member`, unqualified same-type members,
/// `param.member` / `property.member` through a declared simple production type, initializer and
/// type references, parameter/return types and conformances. Ambiguity is recorded per node
/// rather than resolved using names, literals or model assertions.
public struct VerifierRelationIndex: Sendable {
    public typealias P = VerifierProofBundle
    public let nodes: [P.Node]
    public let edges: [P.Edge]
    /// Every issue found (global view, kept for audit).
    public let diagnostics: [String]
    /// Issues attributable to one node: a proof that uses the node cannot be complete.
    public let nodeDiagnostics: [String: [String]]
    let indexedProduction: [String: String]
    let bodies: [String: [VerifierSourceTokens.Token]]
    let constantValues: [String: String]

    struct Declaration {
        let node: P.Node
        let owner: String
        let name: String
        let kind: String            // func | let | var | init | type
        let isStatic: Bool
        let signature: [VerifierSourceTokens.Token]
        let tokens: [VerifierSourceTokens.Token]
        let valueType: String?
        let conformances: [String]
    }

    static let modifiers: Set<String> = ["public", "private", "fileprivate", "internal", "package", "open", "static",
        "mutating", "nonmutating", "nonisolated", "final", "override", "lazy", "weak", "unowned", "indirect",
        "dynamic", "required", "convenience", "optional", "isolated"]
    static let keywords: Set<String> = ["self", "Self", "super", "true", "false", "nil", "return", "if", "else", "guard",
        "switch", "case", "default", "for", "while", "repeat", "in", "let", "var", "func", "try", "await", "throw",
        "throws", "rethrows", "async", "is", "as", "where", "break", "continue", "fallthrough", "defer", "do", "catch",
        "some", "any", "inout", "init", "static", "struct", "enum", "class", "protocol", "extension", "typealias",
        "import", "public", "private", "internal", "fileprivate", "mutating"]

    public init(production: [String: String], protectedPaths: Set<String>) {
        var declarations: [Declaration] = [], issues: [String] = []
        var ownerFiles: [String: Int] = [:]
        var blocked: Set<String> = []          // names whose declarations cannot be resolved exactly
        var globals: Set<String> = []          // file-scope names (can collide with unqualified members)
        let files = Self.productionSources(production, protectedPaths: protectedPaths)
        indexedProduction = files
        guard files.count <= 64, files.values.reduce(0, { $0 + $1.utf8.count }) <= 512_000 else {
            nodes = []; edges = []; diagnostics = ["indexInputBound"]; nodeDiagnostics = [:]
            bodies = [:]; constantValues = [:]; return
        }
        for file in files.keys.sorted() {
            let source = files[file]!
            do {
                let tokens = try VerifierSourceTokens.scan(source)
                let pairs = try VerifierSourceTokens.pairs(tokens)
                for i in tokens.indices where ["extension", "typealias", "class", "actor"].contains(tokens[i].text) && i + 1 < tokens.count {
                    blocked.insert(tokens[i + 1].text)
                }
                var i = 0
                while i < tokens.count {
                    let text = tokens[i].text
                    if ["struct", "enum", "protocol"].contains(text), i + 1 < tokens.count, tokens[i + 1].identifier {
                        let name = tokens[i + 1].text
                        var j = i + 2, conformances: [String] = [], simple = true
                        if j < tokens.count, tokens[j].text == ":" {
                            j += 1
                            while j < tokens.count, tokens[j].text != "{" {
                                if tokens[j].identifier { conformances.append(tokens[j].text) }
                                else if tokens[j].text != "," { simple = false }
                                j += 1
                            }
                        }
                        guard j < tokens.count, tokens[j].text == "{", let end = pairs[j] else { i += 1; continue }
                        guard simple else { blocked.insert(name); i = end + 1; continue }
                        ownerFiles[name, default: 0] += 1
                        let range = tokens[i].line...tokens[j].line
                        let lines = source.components(separatedBy: "\n")
                        let node = P.Node(id: file + ":" + name + ":" + String(range.lowerBound), file: file, symbol: name,
                                          sourceRange: range, exactText: lines[range].joined(separator: "\n"), evidenceType: "typeDeclaration")
                        declarations.append(.init(node: node, owner: name, name: name, kind: "type", isStatic: true,
                                                  signature: [], tokens: [], valueType: nil, conformances: conformances))
                        if text != "protocol" {
                            declarations += Self.members(owner: name, file: file, source: source, tokens: tokens, pairs: pairs,
                                                         start: j + 1, end: end, issues: &issues, blocked: &blocked)
                        }
                        i = end + 1
                    } else if ["func", "let", "var"].contains(text), i + 1 < tokens.count, tokens[i + 1].identifier {
                        globals.insert(tokens[i + 1].text); i += 2
                    } else if text == "{", let end = pairs[i] {
                        i = end + 1
                    } else { i += 1 }
                }
            } catch {
                issues.append("unsupportedSource:\(file):\(error)")
                // Reuse existing Harness declaration evidence: names declared in a file the lexer
                // cannot read are unknown, so any reference to them stays unresolved.
                blocked.formUnion(ContextRelationships.declarations(source).all)
            }
        }
        let grouped = Dictionary(grouping: declarations, by: { $0.node.symbol })
        let unique = grouped.filter { symbol, values in
            let owner = values[0].owner
            let okay = values.count == 1 && ownerFiles[owner] == 1 && !blocked.contains(owner)
            if !okay { issues.append("ambiguousDeclaration:\(symbol)") }
            return okay
        }.mapValues { $0[0] }
        let types = unique.filter { $0.value.kind == "type" }
        let typeNames = Set(types.keys)
        let memberNames = Set(unique.values.filter { $0.kind != "type" }.map(\.name))
        func member(_ owner: String, _ name: String) -> Declaration? {
            guard typeNames.contains(owner), let d = unique[owner + "." + name], d.kind != "type" else { return nil }
            return d
        }
        var relations: [P.Edge] = [], perNode: [String: [String]] = [:]
        var constants: [String: String] = [:]
        for d in unique.values.sorted(by: { $0.node.id < $1.node.id }) {
            var seen: Set<String> = []
            func add(_ target: Declaration, _ kind: P.Relation, _ line: Int) {
                guard target.node.id != d.node.id || kind == .helperCall,
                      seen.insert(target.node.id + ":" + kind.rawValue).inserted else { return }
                relations.append(.init(from: d.node.id, to: target.node.id, relationType: kind,
                                       deterministicReason: "unique production declaration; token line \(line)"))
            }
            func problem(_ text: String) { perNode[d.node.id, default: []].append(text) }
            if d.kind == "type" {
                for conformance in d.conformances {
                    if let target = types[conformance] { add(target, .protocolConformance, d.node.sourceRange.lowerBound) }
                    else if blocked.contains(conformance) { problem("unresolvedConformance:\(conformance)") }
                }
                continue
            }
            if d.kind == "let", d.tokens.count == 1, Double(d.tokens[0].text) != nil { constants[d.node.id] = d.tokens[0].text }
            // Signature: parameter and return types; parameter names shadow everything else.
            var parameterTypes: [String: String] = [:], shadows: Set<String> = []
            let sig = d.signature
            for j in sig.indices where sig[j].text == ":" && j > 0 && sig[j - 1].identifier {
                shadows.insert(sig[j - 1].text)
                if j + 1 < sig.count, sig[j + 1].identifier {
                    let type = sig[j + 1].text
                    parameterTypes[sig[j - 1].text] = type
                    if let target = types[type] { add(target, .parameterType, sig[j + 1].line) }
                    else if blocked.contains(type) { problem("unresolvedType:\(type)") }
                }
            }
            if let arrow = sig.indices.first(where: { $0 + 1 < sig.count && sig[$0].text == "-" && sig[$0 + 1].text == ">" }),
               arrow + 2 < sig.count, sig[arrow + 2].identifier {
                let type = sig[arrow + 2].text
                if let target = types[type] { add(target, .returnType, sig[arrow + 2].line) }
                else if blocked.contains(type) { problem("unresolvedType:\(type)") }
            }
            if (d.kind == "let" || d.kind == "var"), let type = d.valueType {
                if let target = types[type] { add(target, .referenceUse, d.node.sourceRange.lowerBound) }
                else if blocked.contains(type) { problem("unresolvedType:\(type)") }
            }
            let tokens = d.tokens
            // Closures with named parameters and tuple destructuring bind names we cannot track.
            if tokens.indices.contains(where: { tokens[$0].text == "in" && !($0 >= 2 && tokens[$0 - 2].text == "for" && tokens[$0 - 1].identifier) })
                || tokens.indices.contains(where: { ["let", "var"].contains(tokens[$0].text) && ($0 + 1 >= tokens.count || !tokens[$0 + 1].identifier) })
                || tokens.contains(where: { ["func", "struct", "enum", "class", "typealias"].contains($0.text) }) {
                problem("unsupportedLocalBinding:\(d.node.symbol)")
                continue
            }
            for j in tokens.indices where j + 1 < tokens.count {
                if ["let", "var", "for", "case"].contains(tokens[j].text), tokens[j + 1].identifier { shadows.insert(tokens[j + 1].text) }
            }
            // Implicit bindings: `catch` introduces `error`; accessors introduce `newValue`/`oldValue`.
            if tokens.contains(where: { $0.text == "catch" }) { shadows.insert("error") }
            shadows.formUnion(["newValue", "oldValue"])
            for j in tokens.indices {
                let token = tokens[j]
                guard token.identifier, !Self.keywords.contains(token.text) || token.text == "self" || token.text == "Self",
                      j == 0 || tokens[j - 1].text != "." else {
                    // A later chain link (`a.b.c`, `f().c`) has an unknown receiver type.
                    if token.identifier, j > 2, tokens[j - 1].text == ".",
                       tokens[j - 2].text == ")" || tokens[j - 2].text == "]" || tokens[j - 3].text == ".",
                       memberNames.contains(token.text) {
                        problem("unresolvedChain:\(token.text)")
                    }
                    continue
                }
                let isCall = j + 1 < tokens.count && tokens[j + 1].text == "("
                let dotted = j + 2 < tokens.count && tokens[j + 1].text == "." && tokens[j + 2].identifier
                if dotted {
                    let name = tokens[j + 2].text
                    let callsMember = j + 3 < tokens.count && tokens[j + 3].text == "("
                    var receiverType: String? = nil, staticAccess = false
                    if token.text == "self" { receiverType = d.owner }
                    else if token.text == "Self" { receiverType = d.owner; staticAccess = true }
                    else if shadows.contains(token.text) { receiverType = parameterTypes[token.text] }
                    else if let property = member(d.owner, token.text), property.kind != "func" { receiverType = property.valueType }
                    else if typeNames.contains(token.text) { receiverType = token.text; staticAccess = true }
                    guard let receiver = receiverType, typeNames.contains(receiver) else {
                        if memberNames.contains(name) && !["self", "Self"].contains(token.text) { problem("unresolvedReference:\(token.text).\(name)") }
                        continue
                    }
                    guard let target = member(receiver, name), target.isStatic == staticAccess || (receiver == d.owner && !staticAccess && target.isStatic) else {
                        problem("unresolvedReference:\(receiver).\(name)"); continue
                    }
                    guard (target.kind == "func") == callsMember else { problem("unsupportedReference:\(receiver).\(name)"); continue }
                    let kind: P.Relation = callsMember ? (receiver == d.owner ? .helperCall : .directCall)
                        : target.kind == "let" && target.isStatic ? .constantReference : .memberAccess
                    add(target, kind, token.line)
                    continue
                }
                if ["self", "Self"].contains(token.text) || shadows.contains(token.text) { continue }
                if j + 1 < tokens.count, tokens[j + 1].text == ":", j > 0, ["(", ","].contains(tokens[j - 1].text) { continue } // argument label
                if let target = member(d.owner, token.text) {
                    if globals.contains(token.text) { problem("ambiguousUnqualified:\(token.text)"); continue }
                    guard !d.isStatic || target.isStatic else { problem("unsupportedReference:\(token.text)"); continue }
                    guard (target.kind == "func") == isCall else { problem("unsupportedReference:\(token.text)"); continue }
                    add(target, isCall ? .helperCall : target.kind == "let" && target.isStatic ? .constantReference : .memberAccess, token.line)
                } else if let type = types[token.text] {
                    add(type, .referenceUse, token.line)
                } else if blocked.contains(token.text) || (memberNames.contains(token.text) && isCall) {
                    problem("unresolvedReference:\(token.text)")
                }
            }
        }
        nodes = unique.values.map(\.node).sorted { $0.id < $1.id }
        edges = relations.sorted { ($0.from, $0.to, $0.relationType.rawValue) < ($1.from, $1.to, $1.relationType.rawValue) }
        nodeDiagnostics = perNode.mapValues { Array(Set($0)).sorted() }
        diagnostics = Array(Set(issues + perNode.values.flatMap { $0 })).sorted()
        bodies = Dictionary(uniqueKeysWithValues: unique.values.map { ($0.node.id, $0.signature + $0.tokens) })
        constantValues = constants
    }

    static func productionSources(_ production: [String: String], protectedPaths: Set<String>) -> [String: String] {
        production.filter { path, _ in
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            return path.hasSuffix(".swift") && !protectedPaths.contains(path)
                && !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == "Tests" || $0 == "UITests" })
        }
    }

    /// Top-level members of one type body. Unsupported member shapes are skipped with a diagnostic;
    /// they never become nodes, so nothing can reach them.
    private static func members(owner: String, file: String, source: String,
                                tokens: [VerifierSourceTokens.Token], pairs: [Int: Int],
                                start: Int, end: Int, issues: inout [String], blocked: inout Set<String>) -> [Declaration] {
        var result: [Declaration] = [], i = start
        let lines = source.components(separatedBy: "\n")
        while i < end {
            let first = i
            var isStatic = false
            while i < end, modifiers.contains(tokens[i].text) {
                if tokens[i].text == "static" { isStatic = true }
                if i + 1 < end, tokens[i + 1].text == "(", let close = pairs[i + 1] { i = close + 1 } else { i += 1 }
            }
            guard i < end else { break }
            let keyword = tokens[i].text
            if ["struct", "enum", "class", "protocol", "actor", "extension", "typealias", "subscript"].contains(keyword) {
                if i + 1 < end, tokens[i + 1].identifier { blocked.insert(tokens[i + 1].text) }
                var j = i
                while j < end, tokens[j].text != "{", !(keyword == "typealias" && j > i && tokens[j].line != tokens[i].line) { j += 1 }
                i = (j < end && tokens[j].text == "{") ? (pairs[j] ?? j) + 1 : j
                continue
            }
            guard ["func", "let", "var", "init", "case"].contains(keyword) else {
                if tokens[i].text == "{", let close = pairs[i] { i = close + 1 } else { i += 1 }
                continue
            }
            if keyword == "case" {
                // Enum cases are values, not relations; skip to the end of the line.
                let line = tokens[i].line
                while i < end, tokens[i].line == line { if let close = pairs[i], ["(", "["].contains(tokens[i].text) { i = close + 1 } else { i += 1 } }
                continue
            }
            let name = keyword == "init" ? "init" : (i + 1 < end && tokens[i + 1].identifier ? tokens[i + 1].text : "")
            guard !name.isEmpty else { issues.append("unsupportedMember:\(owner)"); i += 1; continue }
            var last = keyword == "init" ? i : i + 1
            var signature: [VerifierSourceTokens.Token] = [], body: [VerifierSourceTokens.Token] = []
            var valueType: String? = nil
            if keyword == "func" || keyword == "init" {
                var open = last + 1
                if open < end, tokens[open].text == "<" { issues.append("unsupportedGeneric:\(owner).\(name)"); blocked.insert(name) }
                if keyword == "init", open < end, tokens[open].text == "?" { open += 1 }
                guard open < end, tokens[open].text == "(", let parametersEnd = pairs[open] else {
                    issues.append("unsupportedSignature:\(owner).\(name)"); i = last + 1; continue
                }
                last = parametersEnd + 1
                while last < end && tokens[last].text != "{" && tokens[last].line <= tokens[parametersEnd].line + 1
                        && !modifiers.contains(tokens[last].text) && !["func", "var", "let", "init"].contains(tokens[last].text) { last += 1 }
                guard last < end, tokens[last].text == "{", let close = pairs[last] else {
                    issues.append("missingBody:\(owner).\(name)"); i = max(last, i + 1); continue
                }
                signature = Array(tokens[(open)...(last - 1)])
                body = last + 1 <= close - 1 ? Array(tokens[(last + 1)...(close - 1)]) : []
                last = close
            } else {
                // let/var: optional `: Type`, then `= expression` and/or `{ accessor body }`.
                var j = last + 1
                if j < end, tokens[j].text == ":" {
                    if j + 1 < end, tokens[j + 1].identifier { valueType = tokens[j + 1].text }
                    j += 1
                    while j < end, tokens[j].line == tokens[first].line, !["=", "{"].contains(tokens[j].text) {
                        if let close = pairs[j], ["(", "["].contains(tokens[j].text) { j = close + 1 } else { j += 1 }
                    }
                }
                if j < end, tokens[j].text == "=" {
                    var k = j + 1
                    let line = tokens[j].line
                    var lastLine = line
                    while k < end, tokens[k].line <= lastLine {
                        if let close = pairs[k], ["(", "[", "{"].contains(tokens[k].text) { lastLine = max(lastLine, tokens[close].line); k = close + 1 }
                        else { k += 1 }
                    }
                    body = Array(tokens[(j + 1)..<k]); last = k - 1
                } else if j < end, tokens[j].text == "{", let close = pairs[j] {
                    body = j + 1 <= close - 1 ? Array(tokens[(j + 1)...(close - 1)]) : []; last = close
                } else {
                    guard !isStatic || keyword == "var" else { issues.append("unsupportedConstant:\(owner).\(name)"); i = j; continue }
                    last = max(i + 1, j - 1)
                }
            }
            let range = tokens[first].line...tokens[last].line
            let sharedBefore = first > start && tokens[first - 1].line == range.lowerBound
            let sharedAfter = last + 1 < tokens.count && tokens[last + 1].line == range.upperBound && last + 1 != end
            if sharedBefore || sharedAfter || (first > 0 && tokens[first - 1].line == range.lowerBound && tokens[first - 1].text == "{") {
                issues.append("sharedDeclarationLine:\(owner).\(name)"); i = last + 1; continue
            }
            let symbol = owner + "." + name
            let node = P.Node(id: file + ":" + symbol + ":" + String(range.lowerBound), file: file, symbol: symbol,
                              sourceRange: range, exactText: lines[range].joined(separator: "\n"),
                              evidenceType: keyword == "func" || keyword == "init" ? "functionDeclaration" : "propertyDeclaration")
            result.append(.init(node: node, owner: owner, name: name, kind: keyword, isStatic: isStatic,
                                signature: signature, tokens: body, valueType: valueType, conformances: []))
            i = last + 1
        }
        return result
    }
}
