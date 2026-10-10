import Foundation

/// Phase 5 (Arm F): Arm E's obligations, bounds and multi-root rules, with path-scoped handling of
/// unresolved references. For every obligation the prover builds the explicit evidence path it relies
/// on (root → traversed RESOLVED_UNIQUE edges → evidence statement). An AMBIGUOUS/UNRESOLVED/OUT_OF_BOUND
/// reference makes that obligation unresolved only if it sits on a statement of that path (or the
/// evidence declaration was not analysed at all); off-path issues are kept as ignored diagnostics.
/// Nothing is ignored silently, and a clause that asks for exclusivity is never admitted here.
public enum VerifierProofObligationsF {
    public typealias P = VerifierProofBundle
    public typealias G = VerifierRelationGraphF
    public typealias Obligation = VerifierProofObligations.Obligation
    typealias Token = VerifierSourceTokens.Token

    public enum Strength: String, Codable, Sendable { case PRESENCE, REACHABLE_PRESENCE, CONDITION_PARTICIPATION, EXCLUSIVITY_UNPROVEN }

    public struct Provenance: Codable, Equatable, Sendable {
        public let obligationID: String
        public let rootID: String?
        public let evidenceNodeIDs: [String]
        public let traversedEdgeIDs: [String]
        public let traversedEdgeStatuses: [String]
        public let onPathIssueIDs: [String]
        public let pathResolutionStatus: String
    }

    public struct ClauseProof: Codable, Equatable, Sendable {
        public let clauseID: String
        public let roots: [String]
        public let obligations: [Obligation]
        public let provenance: [Provenance]
        public let ignoredDiagnosticIDs: [String]
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
        public let proofStrength: Strength
        public let unresolvedSemanticObligations: [String]
        public let averagePathLength: Double
        public let proven: Bool
    }

    static let exclusivityMarkers = ["だけ", "のみ", "に限り", "に限って", "only", "solely", "exclusively"]

    struct Candidate { let root: String; let node: String; let lines: Set<Int>; let body: Bool }

    public static func prove(clause: RequirementVerification.Item, primaryRoot: String?, graph: G, declared: Set<String>,
                             protectedPaths: Set<String> = [], bounds: VerifierProofObligationsE.Bounds = .phase4) -> ClauseProof {
        let byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let anchors = VerifierAdmission.anchors(of: clause.text, declared: declared)
        let lowered = clause.text.lowercased()
        let negated = VerifierProofObligations.negationMarkers.contains { lowered.contains($0) }
        let exclusive = exclusivityMarkers.contains { lowered.contains($0) }
        let perRoot = P.Bounds(depth: bounds.depthPerRoot, additionalFiles: bounds.additionalFiles, nodes: bounds.nodes, edges: bounds.edges)
        func named(_ node: String, _ identifier: String) -> Bool { byID[node]?.symbol == identifier || graph.terminalNames[node] == identifier }
        func fail(_ reason: String) -> ClauseProof {
            .init(clauseID: clause.id, roots: [], obligations: [.init(id: "O1", kind: "root", detail: "-", status: .unsupported, supportingNodes: [], reason: reason)],
                  provenance: [], ignoredDiagnosticIDs: [], graphValid: false, graphReasons: [], gaps: [], nodes: 0, edges: 0, depth: 0, files: 0,
                  contextBytes: 0, namedSymbols: anchors.identifiers.count, namedReachable: 0, proofStrength: .PRESENCE,
                  unresolvedSemanticObligations: [], averagePathLength: 0, proven: false)
        }
        // Roots: same rule as Arm E (validated claim declaration, else the unique clause-named symbol).
        var primary = primaryRoot
        if primary == nil {
            for identifier in anchors.identifiers.sorted() {
                let candidates = graph.nodes.filter { named($0.id, identifier) }
                if candidates.count == 1 { primary = candidates[0].id; break }
            }
        }
        guard let primary, byID[primary] != nil else { return fail("no unique root") }
        var expansions: [G.Expansion] = [graph.expand(rootID: primary, bounds: perRoot)]
        var union = Set(expansions[0].depths.keys), unionEdges = expansions[0].edges
        var blockedNames: [String: String] = [:], bridges: [String: G.Edge] = [:]
        for identifier in anchors.identifiers.sorted() where !union.contains(where: { named($0, identifier) }) {
            let candidates = graph.nodes.filter { named($0.id, identifier) }
            guard !candidates.isEmpty else { continue }
            guard candidates.count <= bounds.roots - expansions.count else {
                blockedNames[identifier] = expansions.count >= bounds.roots ? "root bound reached" : "several declarations could be meant"; continue
            }
            var connected: [(G.Expansion, G.Edge)] = []
            for candidate in candidates {
                let e = graph.expand(rootID: candidate.id, bounds: perRoot)
                let nodes = Set(e.depths.keys)
                if let bridge = graph.edges.first(where: { (union.contains($0.from) && nodes.contains($0.to)) || (nodes.contains($0.from) && union.contains($0.to)) }) {
                    connected.append((e, bridge))
                }
            }
            if connected.count == 1 {
                expansions.append(connected[0].0); union.formUnion(connected[0].0.depths.keys)
                unionEdges += connected[0].0.edges + [connected[0].1]; bridges[connected[0].0.root] = connected[0].1
            } else if connected.count > 1 { blockedNames[identifier] = "several declarations could be meant" }
        }
        var seen: Set<String> = []
        unionEdges = unionEdges.filter { seen.insert(edgeID($0)).inserted }
        let unionNodes = graph.nodes.filter { union.contains($0.id) }
        let files = Set(unionNodes.map(\.file))
        var gaps: [String] = []   // proof-wide: only the union bounds (never widened by path scoping)
        if unionNodes.count > bounds.nodes { gaps.append("unionNodeBound") }
        if unionEdges.count > bounds.edges { gaps.append("unionEdgeBound") }
        if files.subtracting([byID[primary]!.file]).count > bounds.additionalFiles { gaps.append("unionFileBound") }

        // Issues that could invalidate a path: resolution attempts and bound cut-offs of union nodes.
        let issues = (graph.attempts.filter { union.contains($0.from) } + expansions.flatMap(\.outOfBound))
        let issuesByNode = Dictionary(grouping: issues, by: \.from)
        let bodies = Dictionary(uniqueKeysWithValues: unionNodes.map { ($0.id, graph.bodies[$0.id] ?? []) })
        let spans = bodies.mapValues(statementSpans)
        func span(_ node: String, _ line: Int) -> Set<Int> { spans[node]?[line] ?? [line] }
        var usedIssues: Set<String> = []
        var provenance: [Provenance] = []
        var obligations: [Obligation] = []

        /// Builds the explicit path for a candidate and reports on-path issues (never ignores them).
        func path(_ c: Candidate) -> (edges: [G.Edge], issues: [G.Attempt]) {
            guard let expansion = expansions.first(where: { $0.root == c.root }) else { return ([], []) }
            var chain: [G.Edge] = [], cursor = c.node
            while cursor != c.root, let parent = expansion.parents[cursor] { chain.insert(parent, at: 0); cursor = parent.from }
            if let bridge = bridges[c.root] { chain.insert(bridge, at: 0) }
            var points: [(String, Set<Int>, Bool)] = chain.map { e in (e.from, G.line(of: e).map { span(e.from, $0) } ?? [], true) }
            points.append((c.node, Set(c.lines.flatMap { span(c.node, $0) }), c.body))
            let found = points.flatMap { point -> [G.Attempt] in
                (issuesByNode[point.0] ?? []).filter { issue in
                    guard let line = issue.line else { return point.2 }         // declaration not analysed: taints body evidence
                    return point.1.contains(line)
                }
            }
            return (chain, found)
        }
        func settle(_ kind: String, _ detail: String, _ candidates: [Candidate], notFound: String) {
            let id = "O\(obligations.count + 1)"
            var dirty: (Candidate, [G.Edge], [G.Attempt])? = nil
            for c in candidates.sorted(by: { ($0.root, $0.node, $0.lines.sorted().first ?? 0) < ($1.root, $1.node, $1.lines.sorted().first ?? 0) }) {
                let (chain, found) = path(c)
                if found.isEmpty {
                    obligations.append(.init(id: id, kind: kind, detail: detail, status: .resolved, supportingNodes: [c.node], reason: "clean evidence path"))
                    provenance.append(.init(obligationID: id, rootID: c.root, evidenceNodeIDs: [c.root] + chain.map(\.to).filter { $0 != c.root },
                                            traversedEdgeIDs: chain.map(edgeID), traversedEdgeStatuses: chain.map(\.resolutionStatus.rawValue),
                                            onPathIssueIDs: [], pathResolutionStatus: "RESOLVED_UNIQUE"))
                    return
                }
                if dirty == nil { dirty = (c, chain, found) }
            }
            if let (c, chain, found) = dirty {
                usedIssues.formUnion(found.map(\.id))
                let worst = found.contains { $0.resolutionStatus == .AMBIGUOUS } ? "AMBIGUOUS"
                    : found.contains { $0.resolutionStatus == .OUT_OF_BOUND } ? "OUT_OF_BOUND" : "UNRESOLVED"
                obligations.append(.init(id: id, kind: kind, detail: detail, status: .unresolved, supportingNodes: [],
                                         reason: "evidence path crosses \(worst.lowercased()) reference(s): " + found.map { $0.reason + ":" + $0.target }.joined(separator: ", ")))
                provenance.append(.init(obligationID: id, rootID: c.root, evidenceNodeIDs: [c.node], traversedEdgeIDs: chain.map(edgeID),
                                        traversedEdgeStatuses: chain.map(\.resolutionStatus.rawValue), onPathIssueIDs: found.map(\.id), pathResolutionStatus: worst))
            } else {
                obligations.append(.init(id: id, kind: kind, detail: detail, status: .unresolved, supportingNodes: [], reason: notFound))
                provenance.append(.init(obligationID: id, rootID: nil, evidenceNodeIDs: [], traversedEdgeIDs: [], traversedEdgeStatuses: [],
                                        onPathIssueIDs: [], pathResolutionStatus: "NO_PATH"))
            }
        }
        func unsupported(_ kind: String, _ detail: String, _ reason: String) {
            obligations.append(.init(id: "O\(obligations.count + 1)", kind: kind, detail: detail, status: .unsupported, supportingNodes: [], reason: reason))
        }
        func rootOf(_ node: String) -> String { expansions.first { $0.depths[node] != nil }!.root }
        func declarationLine(_ node: String) -> Set<Int> { [byID[node]!.sourceRange.lowerBound] }

        var reachable = 0
        for identifier in anchors.identifiers.sorted() {
            if let why = blockedNames[identifier] { unsupported("requiredSymbolReachable", identifier, why); continue }
            let hits = unionNodes.filter { named($0.id, identifier) }.map(\.id)
            settle("requiredSymbolReachable", identifier, hits.map { Candidate(root: rootOf($0), node: $0, lines: declarationLine($0), body: false) },
                   notFound: declared.contains(identifier) ? "declared but not connected to the proof within bounds" : "no production declaration")
            if obligations.last?.status == .resolved { reachable += 1 }
        }
        for root in expansions.dropFirst().map(\.root) {
            settle("componentConnected", root, [Candidate(root: root, node: root, lines: declarationLine(root), body: false)], notFound: "not connected")
        }
        for literal in Array(Set(anchors.literals)).sorted() {
            let candidates = unionNodes.flatMap { node -> [Candidate] in
                valueLines(literal, bodies[node.id] ?? [], node: node.id, graph: graph).map {
                    Candidate(root: rootOf(node.id), node: node.id, lines: [$0.line], body: !$0.declaration)
                }
            }
            settle("requiredValueParticipates", literal, candidates, notFound: "value not present in any connected declaration")
        }
        let sites = unionNodes.flatMap { comparisonSites(bodies[$0.id] ?? [], node: $0.id, graph: graph, inGraph: union) }
        for (op, value) in anchors.comparisons {
            guard let wanted = VerifierProofObligations.partition(op), let number = Double(value) else { continue }
            let same = sites.filter { $0.value == number && VerifierProofObligations.partition($0.op) == wanted }
            let other = sites.contains { $0.value == number && VerifierProofObligations.partition($0.op) != wanted }
            settle("boundary", "\(op) \(value)", same.map { Candidate(root: rootOf($0.node), node: $0.node, lines: [$0.line], body: true) },
                   notFound: other ? "boundary present with the other inclusivity (not treated as a violation)" : "no comparison with this value")
        }
        var conditionResolved = false
        if anchors.conditional || negated || exclusive {
            let branchCandidates = unionNodes.flatMap { node in
                VerifierProofObligations.conditionLines(bodies[node.id] ?? []).map { Candidate(root: rootOf(node.id), node: node.id, lines: [$0[0].line], body: true) }
            }
            settle("requiredBranch", "branch or condition", branchCandidates, notFound: "no branch/condition reachable")
            let names = Set(anchors.identifiers).union(anchors.literals)
            if names.isEmpty { unsupported("anchorInCondition", "-", "conditional clause names nothing machine-checkable") }
            else {
                let candidates = unionNodes.flatMap { node in
                    VerifierProofObligations.conditionLines(bodies[node.id] ?? []).filter { line in line.contains { names.contains($0.text) } }
                        .map { Candidate(root: rootOf(node.id), node: node.id, lines: [$0[0].line], body: true) }
                }
                settle("anchorInCondition", names.sorted().joined(separator: ","), candidates, notFound: "no named value/symbol inside a condition")
                conditionResolved = obligations.last?.status == .resolved
            }
        }
        if negated { unsupported("negationPolarity", "negated clause", "polarity of a negated requirement is not mechanically checkable") }
        if exclusive { unsupported("exclusivity", "only-when", "presence in a condition does not prove the condition holds only in that case") }
        if obligations.isEmpty { unsupported("clause", "-", "no machine-checkable anchor in clause") }

        let rootNodes = expansions.map(\.root)
        let bundle = P.Bundle(clauseID: clause.id,
            proofObligations: obligations.map { o in .init(id: o.id, kind: o.kind, rootNode: o.supportingNodes.first.map(rootOf) ?? primary, supportingNodes: o.supportingNodes) }
                + rootNodes.map { .init(id: "R-" + $0, kind: "root", rootNode: $0, supportingNodes: [$0]) },
            evidenceNodes: unionNodes,
            relationEdges: unionEdges.map { .init(from: $0.from, to: $0.to, relationType: $0.relationType, deterministicReason: $0.deterministicReason) },
            executionEvidence: [], contradictions: [], unsupportedObligations: obligations.filter { $0.status != .resolved }.map(\.id), admission: .UNCERTAIN)
        let identities = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, P.NodeIdentity($0)) })
        let check = P.validateGraph(bundle, production: graph.production, protectedPaths: protectedPaths, declarations: Set(identities.values),
            relations: Set(graph.edges.compactMap { e in byID[e.from].flatMap { f in byID[e.to].map { P.RelationIdentity(from: f, to: $0, type: e.relationType) } } }),
            clauseRoots: Set(rootNodes.compactMap { identities[$0] }),
            bounds: .init(depth: bounds.depthPerRoot, additionalFiles: bounds.additionalFiles, nodes: bounds.nodes, edges: bounds.edges))
        let ignored = issues.map(\.id).filter { !usedIssues.contains($0) }.sorted()
        let allResolved = obligations.allSatisfy { $0.status == .resolved }
        let pathEdgesClean = provenance.filter { $0.pathResolutionStatus == "RESOLVED_UNIQUE" }.allSatisfy { $0.traversedEdgeStatuses.allSatisfy { $0 == "RESOLVED_UNIQUE" } }
        let comparisonResolved = obligations.contains { $0.kind == "boundary" && $0.status == .resolved }
        let strength: Strength = exclusive ? .EXCLUSIVITY_UNPROVEN : conditionResolved || comparisonResolved ? .CONDITION_PARTICIPATION
            : provenance.contains { !$0.traversedEdgeIDs.isEmpty } ? .REACHABLE_PRESENCE : .PRESENCE
        let lengths = provenance.filter { $0.pathResolutionStatus == "RESOLVED_UNIQUE" }.map { Double($0.traversedEdgeIDs.count) }
        return .init(clauseID: clause.id, roots: rootNodes, obligations: obligations, provenance: provenance, ignoredDiagnosticIDs: ignored,
                     graphValid: check.valid, graphReasons: check.reasons, gaps: gaps.sorted(), nodes: unionNodes.count, edges: unionEdges.count,
                     depth: expansions.map { $0.depths.values.max() ?? 0 }.max() ?? 0, files: files.count, contextBytes: check.contextBytes,
                     namedSymbols: anchors.identifiers.count, namedReachable: reachable, proofStrength: strength,
                     unresolvedSemanticObligations: (exclusive ? ["exclusivity"] : []) + (negated ? ["negationPolarity"] : []),
                     averagePathLength: lengths.isEmpty ? 0 : lengths.reduce(0, +) / Double(lengths.count),
                     proven: gaps.isEmpty && check.valid && allResolved && pathEdgesClean && !exclusive)
    }

    static func edgeID(_ e: G.Edge) -> String { "\(e.from)>\(e.to):\(e.relationType.rawValue)" }

    /// Line → all lines of the statement containing it. A statement continues while `(`/`[` are open or a
    /// line ends/starts with a continuation operator. Braces do not continue a statement.
    static func statementSpans(_ tokens: [Token]) -> [Int: Set<Int>] {
        let byLine = Dictionary(grouping: tokens, by: \.line)
        let lines = byLine.keys.sorted()
        let continuation: Set<String> = ["&", "|", "+", "-", "*", "/", "?", ":", ",", ".", "=", "<", ">", "!"]
        var result: [Int: Set<Int>] = [:], current: [Int] = [], depth = 0
        for (index, line) in lines.enumerated() {
            current.append(line)
            for t in byLine[line]! { if ["(", "["].contains(t.text) { depth += 1 } else if [")", "]"].contains(t.text) { depth -= 1 } }
            let endsOpen = depth > 0 || continuation.contains(byLine[line]!.last!.text)
            let nextStarts = index + 1 < lines.count && [".", "&", "|", "?", ":"].contains(byLine[lines[index + 1]]!.first!.text)
            if !(endsOpen || nextStarts) {
                for l in current { result[l] = Set(current) }
                current = []; depth = max(depth, 0)
            }
        }
        for l in current { result[l] = Set(current) }
        return result
    }

    /// Lines where a literal value participates; `declaration` = it is the constant's own initializer.
    static func valueLines(_ literal: String, _ tokens: [Token], node: String, graph: G) -> [(line: Int, declaration: Bool)] {
        var lines: [(Int, Bool)] = []
        if let number = Double(literal) {
            lines += tokens.filter { Double($0.text) == number }.map { ($0.line, false) }
            if graph.constantValues[node].flatMap(Double.init) == number, let n = graph.nodes.first(where: { $0.id == node }) {
                lines.append((n.sourceRange.lowerBound, true))
            }
            return lines
        }
        switch literal {
        case "true", "false": return tokens.filter { $0.text == literal }.map { ($0.line, false) }
        case "nil":
            return tokens.indices.filter { i in
                tokens[i].text == "nil"
                    || (tokens[i].text == "let" && i > 0 && ["if", "guard", ","].contains(tokens[i - 1].text))
                    || (tokens[i].text == "?" && i + 1 < tokens.count && ["?", "."].contains(tokens[i + 1].text) && tokens[i + 1].offset == tokens[i].end)
            }.map { (tokens[$0].line, false) }
        default:
            guard let file = graph.nodes.first(where: { $0.id == node })?.file, let source = graph.production[file] else { return [] }
            let bytes = Array(source.utf8)
            return tokens.filter { t in t.text == "<literal>" && t.end <= bytes.count && String(decoding: bytes[t.offset..<t.end], as: UTF8.self).contains(literal) }
                .map { ($0.line, false) }
        }
    }

    struct Site { let node: String; let op: String; let value: Double; let line: Int }

    /// Arm E's comparison sites (literal / edge-resolved constant operands; `min`/`max`), with the line.
    static func comparisonSites(_ tokens: [Token], node: String, graph: G, inGraph: Set<String>) -> [Site] {
        func value(_ i: Int) -> Double? {
            guard tokens.indices.contains(i) else { return nil }
            if let n = Double(tokens[i].text) { return i > 0 && tokens[i - 1].text == "-" && tokens[i - 1].end == tokens[i].offset ? -n : n }
            guard tokens[i].identifier else { return nil }
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
            if let n = value(after) { sites.append(.init(node: node, op: op, value: n, line: tokens[i].line)) }
            if let n = value(i - 1) { sites.append(.init(node: node, op: ["<": ">", ">": "<", "<=": ">=", ">=": "<="][op]!, value: n, line: tokens[i].line)) }
        }
        for i in tokens.indices where ["min", "max"].contains(tokens[i].text) && i + 1 < tokens.count && tokens[i + 1].text == "(" {
            var depth = 0, j = i + 1, lastArgument = -1
            while j < tokens.count {
                if tokens[j].text == "(" { depth += 1 } else if tokens[j].text == ")" { depth -= 1; if depth == 0 { break } }
                if depth == 1, tokens[j].text == "," { lastArgument = j + 1 }
                j += 1
            }
            if lastArgument > 0, lastArgument + 1 == j, let n = value(lastArgument) {
                sites.append(.init(node: node, op: tokens[i].text == "min" ? "<=" : ">=", value: n, line: tokens[i].line))
            }
        }
        return sites
    }
}
