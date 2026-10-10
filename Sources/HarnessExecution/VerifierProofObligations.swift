import Foundation

/// Phase 3: mechanically checkable proof obligations over a bounded relation graph.
/// Obligations are derived from clause anchors only (identifiers, literal values, numeric
/// boundaries, conditional/negation markers). This is not natural-language understanding:
/// anything the rules cannot check is `unsupported`, and unsupported means UNCERTAIN.
/// Boundary mismatches are never violations here; they only leave an obligation unresolved.
public enum VerifierProofObligations {
    public typealias P = VerifierProofBundle
    typealias Token = VerifierSourceTokens.Token

    public enum Status: String, Codable, Sendable { case resolved, unresolved, unsupported }

    public struct Obligation: Codable, Equatable, Sendable {
        public let id: String
        public let kind: String
        public let detail: String
        public let status: Status
        public let supportingNodes: [String]
        public let reason: String
    }

    public struct ClauseProof: Codable, Equatable, Sendable {
        public let clauseID: String
        public let root: String?
        public let obligations: [Obligation]
        public let graphValid: Bool
        public let graphReasons: [String]
        public let gaps: [String]
        public let nodes: Int
        public let edges: Int
        public let depth: Int
        public let files: Int
        /// True only when every obligation is resolved inside a complete, valid, bounded graph.
        public let proven: Bool
    }

    static let negationMarkers = ["以外", "除外", "除く", "除いて", "ではない", "でない", "しない", "ないで", "ない",
        "禁止", "unless", "except", "not ", "never", "without", "don't", "doesn't", "isn't", "no longer"]

    /// Partition of a numeric boundary: `lower` = the value itself belongs to the lower side
    /// (`<=` / `>`), `upper` = it belongs to the upper side (`<` / `>=`). Polarity-agnostic:
    /// "N 以下を除外" and "N を超えるものだけ残す" share the same partition.
    static func partition(_ op: String) -> String? {
        switch op { case "<=", ">": return "lower"; case "<", ">=": return "upper"; default: return nil }
    }

    struct Site { let node: String; let op: String; let value: Double }

    public static func prove(clause: RequirementVerification.Item, rootSymbol: String, index: VerifierRelationIndex,
                             declared: Set<String>, protectedPaths: Set<String> = []) -> ClauseProof {
        let expansion = index.expand(rootSymbol: rootSymbol)
        func finish(_ obligations: [Obligation], root: P.Node?, check: P.GraphCheck?) -> ClauseProof {
            let complete = expansion.complete && !expansion.nodes.isEmpty
            let proven = complete && (check?.valid ?? false) && !obligations.isEmpty && obligations.allSatisfy { $0.status == .resolved }
            return .init(clauseID: clause.id, root: root?.id, obligations: obligations, graphValid: check?.valid ?? false,
                         graphReasons: check?.reasons ?? [], gaps: expansion.gaps, nodes: expansion.nodes.count,
                         edges: expansion.edges.count, depth: expansion.maximumDepth,
                         files: Set(expansion.nodes.map(\.file)).count, proven: proven)
        }
        guard let root = expansion.nodes.first(where: { $0.symbol == rootSymbol }) else {
            return finish([.init(id: "O0", kind: "root", detail: rootSymbol, status: .unsupported, supportingNodes: [],
                                 reason: "root is missing or ambiguous in the relation index")], root: nil, check: nil)
        }
        let bodies = Dictionary(uniqueKeysWithValues: expansion.nodes.map { ($0.id, index.bodies[$0.id] ?? []) })
        let order = expansion.nodes.map(\.id)
        var obligations: [Obligation] = []
        func add(_ kind: String, _ detail: String, _ support: [String], _ unresolvedReason: String) {
            obligations.append(.init(id: "O\(obligations.count + 1)", kind: kind, detail: detail,
                                     status: support.isEmpty ? .unresolved : .resolved, supportingNodes: support,
                                     reason: support.isEmpty ? unresolvedReason : "found in bounded graph"))
        }
        let anchors = VerifierAdmission.anchors(of: clause.text, declared: declared)
        let lowered = clause.text.lowercased()
        let negated = negationMarkers.contains { lowered.contains($0) }

        // Required declarations / calls / helpers: every named code identifier must be in the proof graph.
        for identifier in anchors.identifiers.sorted() {
            let hits = expansion.nodes.filter { $0.symbol == identifier || $0.symbol.hasSuffix("." + identifier) }.map(\.id)
            add("requiredSymbolReachable", identifier, hits,
                declared.contains(identifier) ? "declared but not reachable from the root within bounds" : "no production declaration")
        }
        // Required values participate in the bounded graph (string/comment text never counts).
        for literal in Array(Set(anchors.literals)).sorted() {
            let hits = order.filter { id in valueOccurs(literal, in: bodies[id] ?? [], node: id, index: index) }
            add("requiredValueParticipates", literal, hits, "value not present in any reachable declaration")
        }
        // Numeric boundaries: same value, same partition. A different partition is only unresolved.
        let sites = order.flatMap { comparisonSites(bodies[$0] ?? [], node: $0, index: index, graph: Set(order)) }
        for (op, value) in anchors.comparisons {
            guard let wanted = partition(op), let number = Double(value) else { continue }
            let same = sites.filter { $0.value == number && partition($0.op) == wanted }.map(\.node)
            let other = sites.contains { $0.value == number && partition($0.op) != wanted }
            add("boundary", "\(op) \(value)", Array(Set(same)).sorted(),
                other ? "boundary present with the other inclusivity (not treated as a violation)" : "no comparison with this value")
        }
        if anchors.conditional || negated {
            add("requiredBranch", "branch or condition", order.filter { hasBranch(bodies[$0] ?? []) },
                "no branch/condition reachable")
            let named = Set(anchors.identifiers).union(anchors.literals)
            let inCondition = order.filter { id in conditionLines(bodies[id] ?? []).contains { line in
                line.contains { named.contains($0.text) || ($0.text == "nil" && named.contains("nil")) } } }
            if named.isEmpty {
                obligations.append(.init(id: "O\(obligations.count + 1)", kind: "anchorInCondition", detail: "-", status: .unsupported,
                                         supportingNodes: [], reason: "conditional clause names nothing machine-checkable"))
            } else {
                add("anchorInCondition", named.sorted().joined(separator: ","), inCondition, "no named value/symbol inside a condition")
            }
        }
        if negated {
            // Direction of a negated requirement cannot be checked mechanically.
            obligations.append(.init(id: "O\(obligations.count + 1)", kind: "negationPolarity", detail: "negated clause",
                                     status: .unsupported, supportingNodes: [], reason: "polarity of a negated requirement is not mechanically checkable"))
        }
        if obligations.isEmpty {
            obligations.append(.init(id: "O1", kind: "clause", detail: "-", status: .unsupported, supportingNodes: [],
                                     reason: "no machine-checkable anchor in clause"))
        }
        let bundle = P.Bundle(clauseID: clause.id,
            proofObligations: obligations.map { .init(id: $0.id, kind: $0.kind, rootNode: root.id, supportingNodes: $0.supportingNodes) },
            evidenceNodes: expansion.nodes, relationEdges: expansion.edges, executionEvidence: [], contradictions: [],
            unsupportedObligations: obligations.filter { $0.status != .resolved }.map(\.id), admission: .UNCERTAIN)
        let check = index.validateGraph(bundle, production: index.indexedProduction, protectedPaths: protectedPaths,
                                        clauseRootSymbols: [rootSymbol])
        return finish(obligations, root: root, check: check)
    }

    // MARK: token facts

    static func valueOccurs(_ literal: String, in tokens: [Token], node: String, index: VerifierRelationIndex) -> Bool {
        if let number = Double(literal) {
            return tokens.contains { Double($0.text) == number } || index.constantValues[node].flatMap(Double.init) == number
        }
        switch literal {
        case "true", "false": return tokens.contains { $0.text == literal }
        case "nil":
            // Handling nil without the literal: optional binding, coalescing, optional chaining.
            return tokens.indices.contains { i in
                tokens[i].text == "nil"
                    || (tokens[i].text == "let" && i > 0 && ["if", "guard", ","].contains(tokens[i - 1].text))
                    || (tokens[i].text == "?" && i + 1 < tokens.count && ["?", "."].contains(tokens[i + 1].text) && tokens[i + 1].offset == tokens[i].end)
            }
        default:
            guard let file = index.nodes.first(where: { $0.id == node })?.file, let source = index.indexedProduction[file] else { return false }
            let bytes = Array(source.utf8)
            return tokens.contains { token in
                token.text == "<literal>" && token.end <= bytes.count
                    && String(decoding: bytes[token.offset..<token.end], as: UTF8.self).contains(literal)
            }
        }
    }

    /// `a OP b` with OP in <, <=, >, >= (adjacent single-char tokens), plus `min(x, N)` (≤ N) and
    /// `max(x, N)` (≥ N). The numeric side may be a literal or a constant reachable in the graph.
    static func comparisonSites(_ tokens: [Token], node: String, index: VerifierRelationIndex, graph: Set<String>) -> [Site] {
        func value(_ i: Int) -> Double? {
            guard tokens.indices.contains(i) else { return nil }
            if let n = Double(tokens[i].text) {
                return i > 0 && tokens[i - 1].text == "-" && tokens[i - 1].end == tokens[i].offset ? -n : n
            }
            guard tokens[i].identifier else { return nil }
            // Resolve an identifier (or the tail of `Type.name`) to a constant node in this graph.
            let qualified = i + 2 < tokens.count && tokens[i + 1].text == "." && tokens[i + 2].identifier
            let name = qualified ? tokens[i].text + "." + tokens[i + 2].text : tokens[i].text
            let owners = index.nodes.filter { graph.contains($0.id) && ($0.symbol == name || (!qualified && $0.symbol.hasSuffix("." + name))) }
            guard owners.count == 1, let constant = index.constantValues[owners[0].id] else { return nil }
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
            // Mirror: `N < x` is `x > N`.
            if let n = value(i - 1) {
                let mirrored = ["<": ">", ">": "<", "<=": ">=", ">=": "<="][op]!
                sites.append(.init(node: node, op: mirrored, value: n))
            }
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

    static func hasBranch(_ tokens: [Token]) -> Bool {
        tokens.indices.contains { i in
            ["if", "guard", "switch", "while", "case"].contains(tokens[i].text)
                || (i + 1 < tokens.count && ["&", "|"].contains(tokens[i].text) && tokens[i + 1].text == tokens[i].text)
                || (["<", ">"].contains(tokens[i].text) && !(i > 0 && tokens[i - 1].text == "-"))
                || (tokens[i].text == "=" && i + 1 < tokens.count && tokens[i + 1].text == "=")
                || (tokens[i].text == "!" && i + 1 < tokens.count && tokens[i + 1].text == "=")
        }
    }

    /// Lines of the body that are conditions: branch headers, or lines with a comparison/boolean operator.
    static func conditionLines(_ tokens: [Token]) -> [[Token]] {
        Dictionary(grouping: tokens, by: \.line).values.filter(hasBranch).sorted { ($0.first?.line ?? 0) < ($1.first?.line ?? 0) }
    }
}
