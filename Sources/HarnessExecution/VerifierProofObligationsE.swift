import Foundation

/// Phase 4 (Arm E): the Phase 3 proof obligations, unchanged in meaning, evaluated over a bounded
/// multi-root graph. Extra roots come only from clause-named symbols that resolve in the declaration
/// index, and a root joins the proof only if a RESOLVED_UNIQUE edge connects it to the graph built so
/// far (that connection is itself an obligation). A larger graph never resolves an obligation by
/// itself: each obligation still needs its own evidence node.
public enum VerifierProofObligationsE {
    public typealias P = VerifierProofBundle
    public typealias Obligation = VerifierProofObligations.Obligation
    typealias Token = VerifierSourceTokens.Token

    public struct Bounds: Equatable, Sendable {
        public let roots: Int, depthPerRoot: Int, additionalFiles: Int, nodes: Int, edges: Int
        public static let phase4 = Bounds(roots: 3, depthPerRoot: 2, additionalFiles: 4, nodes: 12, edges: 16)
    }

    public struct ClauseProof: Codable, Equatable, Sendable {
        public let clauseID: String
        public let roots: [String]
        public let obligations: [Obligation]
        public let graphValid: Bool
        public let graphReasons: [String]
        public let gaps: [String]
        public let nodes: Int
        public let edges: Int
        public let depth: Int
        public let files: Int
        public let contextBytes: Int
        public let namedSymbols: Int
        public let namedReachable: Int
        /// Contribution audit: union edges resolved through enum cases / typed receivers.
        public let enumCaseEdges: Int
        public let typedMemberEdges: Int
        public let proven: Bool
    }

    public static func prove(clause: RequirementVerification.Item, primaryRoot: String?, graph: VerifierRelationGraphE,
                             declared: Set<String>, protectedPaths: Set<String> = [], bounds: Bounds = .phase4) -> ClauseProof {
        let byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let anchors = VerifierAdmission.anchors(of: clause.text, declared: declared)
        let lowered = clause.text.lowercased()
        let negated = VerifierProofObligations.negationMarkers.contains { lowered.contains($0) }
        let perRoot = P.Bounds(depth: bounds.depthPerRoot, additionalFiles: bounds.additionalFiles, nodes: bounds.nodes, edges: bounds.edges)
        func named(_ node: String, _ identifier: String) -> Bool {
            byID[node]?.symbol == identifier || graph.terminalNames[node] == identifier
        }
        var roots: [String] = [], expansions: [VerifierRelationGraphE.Expansion] = [], gaps: [String] = []
        var union: Set<String> = [], unionEdges: [VerifierRelationGraphE.Edge] = []
        var ambiguous: Set<String> = [], bridges: [String: String] = [:]
        func join(_ e: VerifierRelationGraphE.Expansion) {
            roots.append(e.root); expansions.append(e); union.formUnion(e.depths.keys); unionEdges += e.edges; gaps += e.gaps
        }
        // Primary root: the validated claim's declaration; otherwise the first clause-named symbol
        // with exactly one declaration.
        var primary = primaryRoot
        if primary == nil {
            for identifier in anchors.identifiers.sorted() {
                let candidates = graph.nodes.filter { named($0.id, identifier) }
                if candidates.count == 1 { primary = candidates[0].id; break }
            }
        }
        guard let primary, byID[primary] != nil else {
            return .init(clauseID: clause.id, roots: [], obligations: [.init(id: "O1", kind: "root", detail: "-", status: .unsupported,
                         supportingNodes: [], reason: "no unique root")], graphValid: false, graphReasons: [], gaps: [], nodes: 0, edges: 0,
                         depth: 0, files: 0, contextBytes: 0, namedSymbols: anchors.identifiers.count, namedReachable: 0,
                         enumCaseEdges: 0, typedMemberEdges: 0, proven: false)
        }
        join(graph.expand(rootID: primary, bounds: perRoot))
        // Additional roots for clause-named symbols the graph does not reach yet.
        for identifier in anchors.identifiers.sorted() where !union.contains(where: { named($0, identifier) }) {
            let candidates = graph.nodes.filter { named($0.id, identifier) }
            guard !candidates.isEmpty else { continue }
            guard candidates.count <= bounds.roots - roots.count else {
                gaps.append(roots.count >= bounds.roots ? "rootBound" : "ambiguousRoot:\(identifier)"); ambiguous.insert(identifier); continue
            }
            var connected: [(VerifierRelationGraphE.Expansion, VerifierRelationGraphE.Edge)] = []
            for candidate in candidates {
                let e = graph.expand(rootID: candidate.id, bounds: perRoot)
                let nodes = Set(e.depths.keys)
                if let bridge = graph.edges.first(where: { (union.contains($0.from) && nodes.contains($0.to)) || (nodes.contains($0.from) && union.contains($0.to)) }) {
                    connected.append((e, bridge))
                }
            }
            if connected.count == 1 {
                join(connected[0].0)
                unionEdges.append(connected[0].1)
                bridges[connected[0].0.root] = connected[0].1.from == connected[0].0.root || connected[0].0.depths[connected[0].1.from] != nil
                    ? connected[0].1.from : connected[0].1.to
            } else if connected.count > 1 {
                gaps.append("ambiguousRoot:\(identifier)"); ambiguous.insert(identifier)
            }
        }
        // Union bounds: roots never make the bounds larger.
        var seenEdges: Set<String> = []
        unionEdges = unionEdges.filter { seenEdges.insert($0.from + ">" + $0.to + ":" + $0.relationType.rawValue).inserted }
        let unionNodes = graph.nodes.filter { union.contains($0.id) }
        let files = Set(unionNodes.map(\.file))
        if unionNodes.count > bounds.nodes { gaps.append("unionNodeBound") }
        if unionEdges.count > bounds.edges { gaps.append("unionEdgeBound") }
        if files.subtracting([byID[primary]!.file]).count > bounds.additionalFiles { gaps.append("unionFileBound") }

        let bodies = Dictionary(uniqueKeysWithValues: unionNodes.map { ($0.id, graph.bodies[$0.id] ?? []) })
        let order = unionNodes.map(\.id)
        func rootFor(_ node: String) -> String {
            expansions.first { $0.depths[node] != nil }?.root ?? primary
        }
        var obligations: [Obligation] = []
        func add(_ kind: String, _ detail: String, _ support: [String], _ reason: String) {
            obligations.append(.init(id: "O\(obligations.count + 1)", kind: kind, detail: detail, status: support.isEmpty ? .unresolved : .resolved,
                                     supportingNodes: support, reason: support.isEmpty ? reason : "found in bounded graph"))
        }
        var reachable = 0
        for identifier in anchors.identifiers.sorted() {
            if ambiguous.contains(identifier) {
                obligations.append(.init(id: "O\(obligations.count + 1)", kind: "requiredSymbolReachable", detail: identifier, status: .unsupported,
                                         supportingNodes: [], reason: "several declarations could be meant"))
                continue
            }
            let hits = order.filter { named($0, identifier) }
            reachable += hits.isEmpty ? 0 : 1
            add("requiredSymbolReachable", identifier, hits,
                declared.contains(identifier) ? "declared but not connected to the proof within bounds" : "no production declaration")
        }
        for root in roots.dropFirst() {
            add("componentConnected", root, bridges[root].map { [$0] } ?? [], "no resolved edge joins this component")
        }
        for literal in Array(Set(anchors.literals)).sorted() {
            add("requiredValueParticipates", literal, order.filter { valueOccurs(literal, bodies[$0] ?? [], node: $0, graph: graph) },
                "value not present in any connected declaration")
        }
        let sites = order.flatMap { comparisonSites(bodies[$0] ?? [], node: $0, graph: graph, inGraph: union) }
        for (op, value) in anchors.comparisons {
            guard let wanted = VerifierProofObligations.partition(op), let number = Double(value) else { continue }
            let same = Array(Set(sites.filter { $0.value == number && VerifierProofObligations.partition($0.op) == wanted }.map(\.node))).sorted()
            let other = sites.contains { $0.value == number && VerifierProofObligations.partition($0.op) != wanted }
            add("boundary", "\(op) \(value)", same, other ? "boundary present with the other inclusivity (not treated as a violation)" : "no comparison with this value")
        }
        if anchors.conditional || negated {
            add("requiredBranch", "branch or condition", order.filter { VerifierProofObligations.hasBranch(bodies[$0] ?? []) }, "no branch/condition reachable")
            let named = Set(anchors.identifiers).union(anchors.literals)
            if named.isEmpty {
                obligations.append(.init(id: "O\(obligations.count + 1)", kind: "anchorInCondition", detail: "-", status: .unsupported,
                                         supportingNodes: [], reason: "conditional clause names nothing machine-checkable"))
            } else {
                let hits = order.filter { id in VerifierProofObligations.conditionLines(bodies[id] ?? []).contains { line in
                    line.contains { named.contains($0.text) || isCaseReference($0, in: line, names: named) } } }
                add("anchorInCondition", named.sorted().joined(separator: ","), hits, "no named value/symbol inside a condition")
            }
        }
        if negated {
            obligations.append(.init(id: "O\(obligations.count + 1)", kind: "negationPolarity", detail: "negated clause", status: .unsupported,
                                     supportingNodes: [], reason: "polarity of a negated requirement is not mechanically checkable"))
        }
        if obligations.isEmpty {
            obligations.append(.init(id: "O1", kind: "clause", detail: "-", status: .unsupported, supportingNodes: [], reason: "no machine-checkable anchor in clause"))
        }
        let bundle = P.Bundle(clauseID: clause.id,
            proofObligations: obligations.map { o in .init(id: o.id, kind: o.kind, rootNode: o.supportingNodes.first.map(rootFor) ?? primary, supportingNodes: o.supportingNodes) }
                + roots.map { .init(id: "R-" + $0, kind: "root", rootNode: $0, supportingNodes: [$0]) },
            evidenceNodes: unionNodes,
            relationEdges: unionEdges.map { .init(from: $0.from, to: $0.to, relationType: $0.relationType, deterministicReason: $0.deterministicReason) },
            executionEvidence: [], contradictions: [], unsupportedObligations: obligations.filter { $0.status != .resolved }.map(\.id), admission: .UNCERTAIN)
        let identities = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, P.NodeIdentity($0)) })
        let check = P.validateGraph(bundle, production: graph.production, protectedPaths: protectedPaths,
            declarations: Set(identities.values),
            relations: Set(graph.edges.compactMap { e in byID[e.from].flatMap { f in byID[e.to].map { P.RelationIdentity(from: f, to: $0, type: e.relationType) } } }),
            clauseRoots: Set(roots.compactMap { identities[$0] }),
            bounds: .init(depth: bounds.depthPerRoot, additionalFiles: bounds.additionalFiles, nodes: bounds.nodes, edges: bounds.edges))
        let finalGaps = Array(Set(gaps)).sorted()
        let proven = finalGaps.isEmpty && check.valid && obligations.allSatisfy { $0.status == .resolved }
        return .init(clauseID: clause.id, roots: roots, obligations: obligations, graphValid: check.valid, graphReasons: check.reasons,
                     gaps: finalGaps, nodes: unionNodes.count, edges: unionEdges.count,
                     depth: expansions.map { $0.depths.values.max() ?? 0 }.max() ?? 0, files: files.count, contextBytes: check.contextBytes,
                     namedSymbols: anchors.identifiers.count, namedReachable: reachable,
                     enumCaseEdges: unionEdges.filter { $0.deterministicReason.contains("enum case") }.count,
                     typedMemberEdges: unionEdges.filter { $0.deterministicReason.contains("uniquely typed receiver") }.count, proven: proven)
    }

    /// `.name` inside a condition line where `name` is clause-named (an enum case compared or matched).
    static func isCaseReference(_ token: Token, in line: [Token], names: Set<String>) -> Bool {
        guard let i = line.firstIndex(of: token), i > 0, line[i - 1].text == "." else { return false }
        return names.contains(token.text)
    }

    static func valueOccurs(_ literal: String, _ tokens: [Token], node: String, graph: VerifierRelationGraphE) -> Bool {
        if let number = Double(literal) {
            return tokens.contains { Double($0.text) == number } || graph.constantValues[node].flatMap(Double.init) == number
        }
        switch literal {
        case "true", "false": return tokens.contains { $0.text == literal }
        case "nil":
            return tokens.indices.contains { i in
                tokens[i].text == "nil"
                    || (tokens[i].text == "let" && i > 0 && ["if", "guard", ","].contains(tokens[i - 1].text))
                    || (tokens[i].text == "?" && i + 1 < tokens.count && ["?", "."].contains(tokens[i + 1].text) && tokens[i + 1].offset == tokens[i].end)
            }
        default:
            guard let file = graph.nodes.first(where: { $0.id == node })?.file, let source = graph.production[file] else { return false }
            let bytes = Array(source.utf8)
            return tokens.contains { token in
                token.text == "<literal>" && token.end <= bytes.count && String(decoding: bytes[token.offset..<token.end], as: UTF8.self).contains(literal)
            }
        }
    }

    struct Site { let node: String; let op: String; let value: Double }

    static func comparisonSites(_ tokens: [Token], node: String, graph: VerifierRelationGraphE, inGraph: Set<String>) -> [Site] {
        func value(_ i: Int) -> Double? {
            guard tokens.indices.contains(i) else { return nil }
            if let n = Double(tokens[i].text) {
                return i > 0 && tokens[i - 1].text == "-" && tokens[i - 1].end == tokens[i].offset ? -n : n
            }
            guard tokens[i].identifier else { return nil }
            // The operand's value comes only from a constant this declaration reaches through its own
            // RESOLVED_UNIQUE edges (`name`, `Type.name`, `value.name`), never from a same-named symbol elsewhere.
            let qualified = i + 2 < tokens.count && tokens[i + 1].text == "." && tokens[i + 2].identifier
            let name = qualified ? tokens[i + 2].text : tokens[i].text
            let targets = graph.edges.filter { $0.from == node && inGraph.contains($0.to) && graph.terminalNames[$0.to] == name }.map(\.to)
            guard Set(targets).count == 1, let constant = graph.constantValues[targets[0]] else { return nil }
            return Double(constant)
        }
        var sites: [Site] = []
        for i in tokens.indices {
            let t = tokens[i].text
            guard t == "<" || t == ">" else { continue }
            if i > 0, tokens[i - 1].end == tokens[i].offset, ["-", "<", ">", "="].contains(tokens[i - 1].text) { continue }
            var op = t, after = i + 1
            if after < tokens.count, tokens[after].text == "=", tokens[after].offset == tokens[i].end { op += "="; after += 1 }
            if after < tokens.count, tokens[after].offset == tokens[after - 1].end, ["<", ">"].contains(tokens[after].text) { continue }
            if let n = value(after) { sites.append(.init(node: node, op: op, value: n)) }
            if let n = value(i - 1) { sites.append(.init(node: node, op: ["<": ">", ">": "<", "<=": ">=", ">=": "<="][op]!, value: n)) }
        }
        for i in tokens.indices where ["min", "max"].contains(tokens[i].text) && i + 1 < tokens.count && tokens[i + 1].text == "(" {
            var depth = 0, j = i + 1, lastArgument = -1
            while j < tokens.count {
                if tokens[j].text == "(" { depth += 1 } else if tokens[j].text == ")" { depth -= 1; if depth == 0 { break } }
                if depth == 1, tokens[j].text == "," { lastArgument = j + 1 }
                j += 1
            }
            if lastArgument > 0, lastArgument + 1 == j, let n = value(lastArgument) {
                sites.append(.init(node: node, op: tokens[i].text == "min" ? "<=" : ">=", value: n))
            }
        }
        return sites
    }
}
