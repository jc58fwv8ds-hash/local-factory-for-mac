import Foundation

/// Phase 5 (Arm F) relation graph: identical resolution rules to Arm E's graph (which stays unchanged),
/// but every attempted relation also records the source line where it occurs and a stable id, so a
/// proof can tell whether an unresolved reference lies on the evidence path it actually uses. Arm E's graph: enum cases as nodes, qualified and contextual `.case` references
/// resolved only from surrounding type information, and `value.member` chains through values whose
/// type is determined uniquely (declared, parameter, property, return, initializer, assignment from a
/// typed symbol). Every attempted relation carries a resolution status; only RESOLVED_UNIQUE edges exist.
public struct VerifierRelationGraphF: Sendable {
    public typealias P = VerifierProofBundle
    typealias Token = VerifierSourceTokens.Token
    public typealias Resolution = VerifierRelationGraphE.Resolution

    public struct Edge: Codable, Equatable, Sendable {
        public let from: String
        public let to: String
        public let relationType: P.Relation
        public let deterministicReason: String
        public let resolutionStatus: Resolution
    }
    public struct Attempt: Codable, Equatable, Sendable {
        public let id: String
        public let from: String
        public let target: String
        public let resolutionStatus: Resolution
        public let reason: String
        /// Source line of the reference; nil = the issue concerns the whole declaration.
        public let line: Int?
    }

    public let nodes: [P.Node]
    public let edges: [Edge]
    public let attempts: [Attempt]
    public let diagnostics: [String]
    public let nodeDiagnostics: [String: [String]]
    let production: [String: String]
    let bodies: [String: [Token]]
    let constantValues: [String: String]
    let terminalNames: [String: String]

    typealias Declaration = VerifierRelationGraphE.Declaration

    public init(production input: [String: String], protectedPaths: Set<String>) {
        var declarations: [Declaration] = [], issues: [String] = []
        var ownerFiles: [String: Int] = [:], blocked: Set<String> = [], globals: Set<String> = []
        let files = VerifierRelationIndex.productionSources(input, protectedPaths: protectedPaths)
        production = files
        guard files.count <= 64, files.values.reduce(0, { $0 + $1.utf8.count }) <= 512_000 else {
            nodes = []; edges = []; attempts = []; diagnostics = ["indexInputBound"]; nodeDiagnostics = [:]
            bodies = [:]; constantValues = [:]; terminalNames = [:]; return
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
                                if tokens[j].identifier { conformances.append(tokens[j].text) } else if tokens[j].text != "," { simple = false }
                                j += 1
                            }
                        }
                        guard j < tokens.count, tokens[j].text == "{", let end = pairs[j] else { i += 1; continue }
                        guard simple else { blocked.insert(name); i = end + 1; continue }
                        ownerFiles[name, default: 0] += 1
                        let range = tokens[i].line...tokens[j].line
                        let lines = source.components(separatedBy: "\n")
                        let node = P.Node(id: file + ":" + name + ":" + String(range.lowerBound), file: file, symbol: name, sourceRange: range,
                                          exactText: lines[range].joined(separator: "\n"), evidenceType: text == "enum" ? "enumDeclaration" : "typeDeclaration")
                        declarations.append(.init(node: node, owner: name, name: name, kind: "type", isStatic: true, isEnum: text == "enum",
                                                  signature: [], tokens: [], valueType: nil, returnType: nil, conformances: conformances))
                        if text != "protocol" {
                            declarations += VerifierRelationGraphE.members(owner: name, isEnum: text == "enum", file: file, source: source, tokens: tokens,
                                                         pairs: pairs, start: j + 1, end: end, issues: &issues, blocked: &blocked)
                        }
                        i = end + 1
                    } else if ["func", "let", "var"].contains(text), i + 1 < tokens.count, tokens[i + 1].identifier {
                        globals.insert(tokens[i + 1].text); i += 2
                    } else if text == "{", let end = pairs[i] { i = end + 1 } else { i += 1 }
                }
            } catch {
                issues.append("unsupportedSource:\(file):\(error)")
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
        var caseOwners: [String: [String]] = [:]
        for d in unique.values where d.kind == "case" { caseOwners[d.name, default: []].append(d.owner) }
        func member(_ owner: String, _ name: String) -> Declaration? {
            guard typeNames.contains(owner), let d = unique[owner + "." + name], d.kind != "type" else { return nil }
            return d
        }
        var relations: [Edge] = [], tries: [Attempt] = [], perNode: [String: [String]] = [:], constants: [String: String] = [:]
        for d in unique.values.sorted(by: { $0.node.id < $1.node.id }) {
            var seen: Set<String> = []
            func add(_ target: Declaration, _ kind: P.Relation, _ reason: String, _ line: Int) {
                guard target.node.id != d.node.id || kind == .helperCall, seen.insert(target.node.id + ":" + kind.rawValue).inserted else { return }
                relations.append(.init(from: d.node.id, to: target.node.id, relationType: kind,
                                       deterministicReason: reason + "; token line \(line)", resolutionStatus: .RESOLVED_UNIQUE))
            }
            var currentLine: Int? = d.node.sourceRange.lowerBound   // signature issues sit on the declaration line
            func problem(_ status: Resolution, _ target: String, _ reason: String) {
                perNode[d.node.id, default: []].append(reason + ":" + target)
                tries.append(.init(id: "\(d.node.id)#\(tries.count)", from: d.node.id, target: target, resolutionStatus: status,
                                   reason: reason, line: currentLine))
            }
            func typeRef(_ type: String?, _ kind: P.Relation, _ line: Int) {
                guard let type else { return }
                if let target = types[type] { add(target, kind, "declared type", line) }
                else if blocked.contains(type) { problem(.UNRESOLVED, type, "unresolvedType") }
            }
            switch d.kind {
            case "type":
                for conformance in d.conformances {
                    if let target = types[conformance] { add(target, .protocolConformance, "declared conformance", d.node.sourceRange.lowerBound) }
                    else if blocked.contains(conformance) { problem(.UNRESOLVED, conformance, "unresolvedConformance") }
                }
                continue
            case "case":
                if let owner = types[d.owner] { add(owner, .declaration, "enum case of \(d.owner)", d.node.sourceRange.lowerBound) }
                if d.tokens.count == 1, Double(d.tokens[0].text) != nil { constants[d.node.id] = d.tokens[0].text }
                continue
            default: break
            }
            if d.kind == "let", d.tokens.count == 1, Double(d.tokens[0].text) != nil { constants[d.node.id] = d.tokens[0].text }
            // Environment: parameters (typed), then locals as they are declared.
            var env: [String: String?] = [:]
            let sig = d.signature
            for j in sig.indices where sig[j].text == ":" && j > 0 && sig[j - 1].identifier {
                let type = j + 1 < sig.count && sig[j + 1].identifier ? sig[j + 1].text : nil
                env[sig[j - 1].text] = .some(type)
                typeRef(type, .parameterType, sig[j].line)
            }
            typeRef(d.returnType, .returnType, d.node.sourceRange.lowerBound)
            if d.kind == "let" || d.kind == "var" { typeRef(d.valueType, .referenceUse, d.node.sourceRange.lowerBound) }
            let tokens = d.tokens
            if tokens.indices.contains(where: { tokens[$0].text == "in" && !($0 >= 2 && tokens[$0 - 2].text == "for" && tokens[$0 - 1].identifier) })
                || tokens.indices.contains(where: { ["let", "var"].contains(tokens[$0].text) && ($0 + 1 >= tokens.count || !tokens[$0 + 1].identifier) })
                || tokens.contains(where: { ["func", "struct", "enum", "class", "typealias"].contains($0.text) }) {
                perNode[d.node.id, default: []].append("unsupportedLocalBinding:\(d.node.symbol)")
                tries.append(.init(id: "\(d.node.id)#\(tries.count)", from: d.node.id, target: d.node.symbol, resolutionStatus: .UNRESOLVED,
                                   reason: "unsupportedLocalBinding", line: nil))
                continue
            }
            if tokens.contains(where: { $0.text == "catch" }) { env["error"] = .some(nil) }
            env["newValue"] = .some(d.valueType); env["oldValue"] = .some(d.valueType)
            let pairs = (try? VerifierSourceTokens.pairs(tokens)) ?? [:]

            /// Resolves `head(.link)*` starting at `start`. Returns the type after the chain and the index
            /// after it; records edges for every resolved link and a problem for the first unresolvable
            /// production-named link. `record` = false only computes a type (no edges).
            func chain(_ start: Int, record: Bool) -> (type: String?, end: Int) {
                guard start < tokens.count, tokens[start].identifier else { return (nil, start) }
                let head = tokens[start].text
                var type: String? = nil, staticAccess = false, i = start + 1
                if head == "self" { type = d.owner }
                else if head == "Self" { type = d.owner; staticAccess = true }
                else if let local = env[head] { type = local }
                else if let own = member(d.owner, head), own.kind != "case" {
                    if own.kind == "func" {
                        guard i < tokens.count, tokens[i].text == "(", let close = pairs[i] else { return (nil, i) }
                        if record {
                            if globals.contains(head) { problem(.AMBIGUOUS, head, "ambiguousUnqualified") }
                            else if d.isStatic && !own.isStatic { problem(.UNRESOLVED, head, "unsupportedReference") }
                            else { add(own, .helperCall, "same-type call", tokens[start].line) }
                        }
                        type = own.returnType; i = close + 1
                    } else {
                        if record {
                            if globals.contains(head) { problem(.AMBIGUOUS, head, "ambiguousUnqualified") }
                            else if d.isStatic && !own.isStatic { problem(.UNRESOLVED, head, "unsupportedReference") }
                            else { add(own, own.kind == "let" && own.isStatic ? .constantReference : .memberAccess, "same-type member", tokens[start].line) }
                        }
                        type = own.valueType
                    }
                } else if let t = types[head] {
                    type = head; staticAccess = true
                    if i < tokens.count, tokens[i].text == "(" , let close = pairs[i] {
                        if record { add(t, .referenceUse, "initializer", tokens[start].line) }
                        staticAccess = false; i = close + 1
                    } else if record, !(i < tokens.count && tokens[i].text == ".") { add(t, .referenceUse, "type reference", tokens[start].line) }
                } else {
                    if record, blocked.contains(head) || (memberNames.contains(head) && i < tokens.count && tokens[i].text == "(") {
                        problem(.UNRESOLVED, head, "unresolvedReference")
                    }
                    return (nil, i)
                }
                while i + 1 < tokens.count, tokens[i].text == ".", tokens[i + 1].identifier {
                    let name = tokens[i + 1].text
                    let calls = i + 2 < tokens.count && tokens[i + 2].text == "("
                    guard let receiver = type, typeNames.contains(receiver) else {
                        if record, memberNames.contains(name) { problem(.UNRESOLVED, name, "unresolvedReceiverType") }
                        return (nil, i + 2)
                    }
                    guard let target = member(receiver, name) else {
                        if record { problem(.UNRESOLVED, receiver + "." + name, "unresolvedReference") }
                        return (nil, i + 2)
                    }
                    if target.kind == "case" {
                        guard staticAccess else { if record { problem(.UNRESOLVED, receiver + "." + name, "unsupportedReference") }; return (nil, i + 2) }
                        if record { add(target, .memberAccess, "qualified enum case", tokens[i + 1].line) }
                        type = receiver; staticAccess = false; i += 2
                        if i < tokens.count, tokens[i].text == "(", let close = pairs[i] { i = close + 1 }
                        continue
                    }
                    guard target.isStatic == staticAccess || (receiver == d.owner && !staticAccess && target.isStatic),
                          (target.kind == "func") == calls else {
                        if record { problem(.UNRESOLVED, receiver + "." + name, "unsupportedReference") }
                        return (nil, i + 2)
                    }
                    if record {
                        let kind: P.Relation = calls ? (receiver == d.owner ? .helperCall : .directCall)
                            : target.kind == "let" && target.isStatic ? .constantReference : .memberAccess
                        add(target, kind, "member of uniquely typed receiver \(receiver)", tokens[i + 1].line)
                    }
                    staticAccess = false
                    if calls, let close = pairs[i + 2] { type = target.returnType; i = close + 1 } else { type = target.valueType; i += 2 }
                }
                return (type, i)
            }
            /// Type of the operand ending just before `index` (simple `a`, `self.a`, `a.b`).
            func operandBefore(_ index: Int) -> String? {
                var s = index - 1
                guard s >= 0, tokens[s].identifier else { return nil }
                while s >= 2, tokens[s - 1].text == ".", tokens[s - 2].identifier { s -= 2 }
                let r = chain(s, record: false)
                return r.end == index ? r.type : nil
            }
            func expectedEnum(at dot: Int) -> (String?, String) {
                // switch subject
                var context: (String?, String) = (nil, "no context")
                if dot > 0, tokens[dot - 1].text == "case" || tokens[dot - 1].text == "," {
                    var k = dot - 1
                    while k > 0, tokens[k].text != "case" { k -= 1 }
                    // A comma continues a case pattern only if nothing but patterns lie between `case` and here.
                    guard tokens[k].text == "case",
                          !tokens[k..<dot].contains(where: { [":", "(", "{", "=", "[", "return"].contains($0.text) }) else { return (nil, "no context") }
                    if k > 0, ["if", "guard", "while"].contains(tokens[k - 1].text) {
                        if let eq = tokens[dot...].firstIndex(where: { $0.text == "=" }) { return (chain(eq + 1, record: false).type, "if case pattern") }
                    }
                    for s in tokens.indices where tokens[s].text == "switch" {
                        guard let open = tokens[(s + 1)...].firstIndex(where: { $0.text == "{" }), let close = pairs[open], open < dot, dot < close else { continue }
                        context = (chain(s + 1, record: false).type, "switch case")
                    }
                    return context
                }
                if dot >= 2, tokens[dot - 1].text == "=", ["=", "!"].contains(tokens[dot - 2].text) { return (operandBefore(dot - 2), "equality") }
                if dot >= 1, tokens[dot - 1].text == "=" {
                    if dot >= 2, ["<", ">"].contains(tokens[dot - 2].text) { return (nil, "no context") }
                    if dot >= 4, tokens[dot - 3].text == ":", tokens[dot - 2].identifier { return (tokens[dot - 2].text, "typed declaration") }
                    return (operandBefore(dot - 1), "assignment")
                }
                if dot == 0 { return (d.kind == "func" ? d.returnType : d.valueType, "initializer") }
                if tokens[dot - 1].text == "return" { return (d.kind == "func" || d.kind == "init" ? d.returnType : d.valueType, "return") }
                if dot + 3 < tokens.count, tokens[dot + 2].text == "=", tokens[dot + 3].text == "=" { return (chain(dot + 4, record: false).type, "equality") }
                return context
            }
            var j = 0
            while j < tokens.count {
                let t = tokens[j]
                currentLine = t.line
                if ["let", "var"].contains(t.text), j + 1 < tokens.count, tokens[j + 1].identifier {
                    let name = tokens[j + 1].text
                    var type: String? = nil
                    if j + 3 < tokens.count, tokens[j + 2].text == ":", tokens[j + 3].identifier { type = tokens[j + 3].text }
                    else if j + 3 < tokens.count, tokens[j + 2].text == "=" {
                        let r = chain(j + 3, record: false)
                        let endsStatement = r.end >= tokens.count || tokens[r.end].line != tokens[r.end - 1].line
                            || ["else", "{", ",", ";"].contains(tokens[r.end].text)
                        type = endsStatement ? r.type : nil
                    }
                    // `let a = a.b` would make the right-hand side resolve through the new binding: refuse.
                    let rhsMentionsName = tokens[(j + 2)...].prefix { $0.line == tokens[j].line }.contains { $0.text == name }
                    if rhsMentionsName { type = nil; problem(.UNRESOLVED, name, "selfShadowingBinding") }
                    if let previous = env[name], previous != type { env[name] = .some(nil) } else { env[name] = .some(type) }
                    j += 2; continue
                }
                if ["for", "case"].contains(t.text), j + 1 < tokens.count, tokens[j + 1].identifier, env[tokens[j + 1].text] == nil {
                    env[tokens[j + 1].text] = .some(nil)
                }
                if t.text == ".", j + 1 < tokens.count, tokens[j + 1].identifier,
                   j == 0 || !((tokens[j - 1].identifier && (!VerifierRelationIndex.keywords.contains(tokens[j - 1].text)
                                                             || ["self", "Self", "super"].contains(tokens[j - 1].text)))
                               || [")", "]", "?", "!"].contains(tokens[j - 1].text) || Double(tokens[j - 1].text) != nil) {
                    let name = tokens[j + 1].text
                    let (expected, how) = expectedEnum(at: j)
                    if let expected, types[expected]?.isEnum == true {
                        if let target = member(expected, name), target.kind == "case" { add(target, .memberAccess, "contextual enum case (\(how))", tokens[j + 1].line) }
                        else if let target = member(expected, name), target.isStatic {
                            add(target, target.kind == "func" ? .directCall : .memberAccess, "contextual static member (\(how))", tokens[j + 1].line)
                        } else { problem(.UNRESOLVED, expected + "." + name, "unknownCase") }
                    } else if expected == nil, let owners = caseOwners[name], !owners.isEmpty {
                        problem(.AMBIGUOUS, "." + name, "contextualCaseWithoutUniqueType")
                    } else if blocked.contains(name) { problem(.UNRESOLVED, "." + name, "unresolvedReference") }
                    j += 2; continue
                }
                if t.identifier, j == 0 || tokens[j - 1].text != ".",
                   !(j + 1 < tokens.count && tokens[j + 1].text == ":" && j > 0 && ["(", ","].contains(tokens[j - 1].text)),
                   !VerifierRelationIndex.keywords.contains(t.text) || ["self", "Self"].contains(t.text) {
                    // Unlike Arm E, keep scanning inside call arguments: a reference hidden in an argument must be
                    // visible (resolved or not) for path-scoped checks. Chain links (`.member`) are skipped below.
                    _ = chain(j, record: true)
                    j += 1; continue
                }
                j += 1
            }
        }
        nodes = unique.values.map(\.node).sorted { $0.id < $1.id }
        edges = relations.sorted { ($0.from, $0.to, $0.relationType.rawValue) < ($1.from, $1.to, $1.relationType.rawValue) }
        attempts = tries
        nodeDiagnostics = perNode.mapValues { Array(Set($0)).sorted() }
        diagnostics = Array(Set(issues + perNode.values.flatMap { $0 })).sorted()
        bodies = Dictionary(uniqueKeysWithValues: unique.values.map { ($0.node.id, $0.signature + $0.tokens) })
        constantValues = constants
        terminalNames = Dictionary(uniqueKeysWithValues: unique.values.map { ($0.node.id, $0.name) })
    }
}
