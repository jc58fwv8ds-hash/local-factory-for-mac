import Foundation

/// Phase 6 (Arm G): Semantic Obligation Gate. Separates presence/participation (Arm F proofs) from
/// behavioural relations. Relations are recognised from lexical clause markers only; each is proven
/// only from the parsed condition structure of declarations the Arm F proof already relies on.
/// Unclassifiable behaviour is UNSUPPORTED; exclusivity beyond the direct pattern, independence,
/// preservation and negation polarity are UNPROVEN. Anything unproven keeps the clause UNCERTAIN.
public enum VerifierSemanticObligationsG {
    public typealias CS = VerifierConditionStructure

    public enum RelationType: String, Codable, Sendable {
        case conjunction, disjunction, implication, exclusivity, independence, preservation, negatedCondition, comparison, unsupported
    }
    public enum Status: String, Codable, Sendable {
        case RELATION_PROVEN, RELATION_UNPROVEN, EXCLUSIVITY_UNPROVEN, INDEPENDENCE_UNPROVEN, PRESERVATION_UNPROVEN,
             NEGATION_UNPROVEN, UNSUPPORTED_SEMANTIC_OBLIGATION
    }
    public enum Strength: String, Codable, Sendable {
        case PRESENCE, REACHABLE_PRESENCE, CONDITION_PARTICIPATION, RELATION_PROVEN, SEMANTIC_REQUIREMENT_UNPROVEN
    }

    public struct SemanticObligation: Codable, Equatable, Sendable {
        public let semanticObligationID: String
        public let relationType: RelationType
        public let detail: String
        public let operandEvidence: [String]
        public let operatorEvidence: String?
        public let sourceRange: String?
        public let resolutionStatus: Status
    }

    public struct Result: Codable, Equatable, Sendable {
        public let obligations: [SemanticObligation]
        public let presenceOnlyClause: Bool
        public let strength: Strength
        public let passes: Bool
        public let sitesExamined: Int
    }

    static let conditional = ["なら", "場合", "とき", "たら", "ければ", "れば"]
    static let englishConditional = [" only when ", " whenever ", " when ", " if "]
    static let conjunction = ["かつ", "且つ", "両方", " and ", "both "]
    static let disjunction = ["または", "もしくは", "あるいは", "いずれか", " or ", "either "]
    static let exclusivity = ["だけ", "のみ", "に限り", "に限って", "only", "solely", "exclusively"]
    static let independence = ["regardless", "関係なく", "かかわらず", "関わらず", "問わず", "irrespective", "no matter"]
    static let preservation = ["今まで", "従来", "これまで", "そのまま", "変えない", "変更しない", "維持", "as before", "unchanged",
                               "current behaviour", "current behavior", "otherwise", "stay the same", "same as before", "keep their", "keeps its"]
    static let negation = VerifierProofObligations.negationMarkers + ["unless", "以外"]
    static let declaration = ["追加", "add ", "adds ", "introduce", "新しい", "new case", "new property", "rename", "プロパティ", "を定義", "declare"]

    struct Parts { let condition: String?; let consequence: String? }

    /// Splits a clause into condition and consequence text at the first conditional marker.
    static func parts(_ text: String) -> Parts {
        let lower = text.lowercased()
        if let marker = conditional.compactMap({ m in lower.range(of: m).map { ($0, m) } }).min(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            return .init(condition: String(lower[..<marker.0.lowerBound]), consequence: String(lower[marker.0.upperBound...]))
        }
        if lower.hasPrefix("if ") || lower.hasPrefix("when ") {
            let comma = lower.firstIndex(of: ",") ?? lower.endIndex
            return .init(condition: String(lower[lower.index(lower.startIndex, offsetBy: lower.hasPrefix("if ") ? 3 : 5)..<comma]),
                         consequence: comma < lower.endIndex ? String(lower[lower.index(after: comma)...]) : nil)
        }
        for marker in englishConditional {
            if let r = lower.range(of: marker) { return .init(condition: String(lower[r.upperBound...]), consequence: String(lower[..<r.lowerBound])) }
        }
        return .init(condition: nil, consequence: nil)
    }

    struct Anchors { let comparisons: [(String, Double)]; let cases: Set<String>; let identifiers: Set<String>; let literals: Set<String>
        var isEmpty: Bool { comparisons.isEmpty && cases.isEmpty && identifiers.isEmpty && literals.isEmpty } }

    static func anchors(_ text: String, original: String, declared: Set<String>, caseNames: Set<String>) -> Anchors {
        // Keep code identifiers' case: re-extract from the original clause restricted to identifiers present in `text`.
        let a = VerifierAdmission.anchors(of: original, declared: declared)
        let lower = text.lowercased()
        let local = VerifierAdmission.anchors(of: text, declared: declared)
        let ids = a.identifiers.filter { lower.contains($0.lowercased()) }
        return .init(comparisons: local.comparisons.compactMap { c in Double(c.value).map { (c.op, $0) } },
                     cases: Set(ids.filter { caseNames.contains($0) }), identifiers: Set(ids.filter { !caseNames.contains($0) }),
                     literals: Set(local.literals.filter { ["true", "false", "nil"].contains($0) || Double($0) != nil }))
    }

    public static func evaluate(clause: RequirementVerification.Item, proof: VerifierProofObligationsF.ClauseProof,
                                graph: VerifierRelationGraphF, declared: Set<String>) -> Result {
        let text = clause.text, lower = text.lowercased()
        let caseNames = Set(graph.nodes.filter { $0.evidenceType == "enumCase" }.compactMap { graph.terminalNames[$0.id] })
        // Declarations the Arm F proof relies on (roots and clean-path evidence), path-scoped as in Arm F.
        let nodes = Set(proof.roots + proof.provenance.filter { $0.pathResolutionStatus == "RESOLVED_UNIQUE" }.flatMap(\.evidenceNodeIDs))
        var sites: [CS.Site] = [], returns: [(String, Int, [CS.Tree])] = []
        for node in nodes.sorted() {
            let x = CS.extract(graph.bodies[node] ?? [], node: node)
            let issues = graph.attempts.filter { $0.from == node && $0.resolutionStatus != .RESOLVED_UNIQUE }
            // A site whose lines hold an unresolved reference is not evidence (same path-scoping as Arm F).
            sites += x.sites.filter { site in !issues.contains { $0.line.map(site.lines.contains) ?? true } }
            returns += x.returns
        }
        var obligations: [SemanticObligation] = []
        func add(_ type: RelationType, _ detail: String, _ status: Status, operands: [String] = [], op: String? = nil, range: String? = nil) {
            obligations.append(.init(semanticObligationID: "S\(obligations.count + 1)", relationType: type, detail: detail,
                                     operandEvidence: operands, operatorEvidence: op, sourceRange: range, resolutionStatus: status))
        }
        func has(_ markers: [String]) -> Bool { markers.contains { lower.contains($0) } }
        let parts = parts(text)
        let conditionAnchors = parts.condition.map { anchors($0, original: text, declared: declared, caseNames: caseNames) }
        let resultAnchors = parts.consequence.map { anchors($0, original: text, declared: declared, caseNames: caseNames) }
        let wholeAnchors = anchors(text, original: text, declared: declared, caseNames: caseNames)

        if has(preservation) { add(.preservation, "otherwise unchanged / as before", .PRESERVATION_UNPROVEN) }
        if has(independence) { add(.independence, "regardless of", .INDEPENDENCE_UNPROVEN) }
        if has(negation) { add(.negatedCondition, "negation / unless", .NEGATION_UNPROVEN) }
        // Comparison structure: exact operator (mirroring allowed), never mere partition compatibility.
        for (op, value) in wholeAnchors.comparisons {
            if let (site, atom) = find(sites, where: { node, atom in compares(atom, op: op, value: value, graph: graph, node: node) }) {
                add(.comparison, "\(op) \(fmt(value))", .RELATION_PROVEN, operands: [atom.text], op: atom.op, range: "\(site.node)@\(atom.line)")
            } else { add(.comparison, "\(op) \(fmt(value))", .RELATION_UNPROVEN) }
        }
        if let condition = parts.condition {
            let conj = conjunction.compactMap { m in condition.range(of: m) }.first
            let disj = disjunction.compactMap { m in condition.range(of: m) }.first
            // The operator must belong to the site that produces the clause's result; an `&&` elsewhere in the
            // same function proves nothing about this requirement.
            let requiredResult = resultAnchors.flatMap(resultToken)
            let producing = sites.filter { site in requiredResult.map { r in site.result.map { matchesResult($0, r) } ?? false } ?? false }
            for (range, type) in [(conj, RelationType.conjunction), (disj, RelationType.disjunction)] {
                guard let range else { continue }
                let left = anchors(String(condition[..<range.lowerBound]), original: text, declared: declared, caseNames: caseNames)
                let right = anchors(String(condition[range.upperBound...]), original: text, declared: declared, caseNames: caseNames)
                guard !left.isEmpty, !right.isEmpty, requiredResult != nil else {
                    add(type, "operands or result not machine-identifiable", .UNSUPPORTED_SEMANTIC_OBLIGATION); continue
                }
                if let site = producing.first(where: { chainHas($0.tree, type == .conjunction ? "and" : "or", left, right, graph) }) {
                    add(type, type == .conjunction ? "A AND B" : "A OR B", .RELATION_PROVEN, operands: [describe(left), describe(right)],
                        op: type == .conjunction ? "&&" : "||", range: "\(site.node)@\(site.lines.lowerBound)")
                } else { add(type, type == .conjunction ? "A AND B" : "A OR B", .RELATION_UNPROVEN) }
            }
            let exclusive = has(exclusivity)
            guard let conditionAnchors, !conditionAnchors.isEmpty, let resultAnchors, let result = resultToken(resultAnchors) else {
                add(exclusive ? .exclusivity : .implication, "condition or result not machine-identifiable", .UNSUPPORTED_SEMANTIC_OBLIGATION)
                return finish(obligations, proof: proof, presenceOnly: false, sites: sites.count)
            }
            if exclusive {
                // Only when C → R: every place that yields R is guarded by C as a top-level conjunct.
                let producing = returns.filter { matchesResult($0.0, result) }
                let guarded = producing.allSatisfy { r in r.2.contains { conjunctMatches($0, conditionAnchors, graph) } }
                let direct = sites.filter { ($0.kind == .booleanReturn || $0.kind == .ternary) && $0.result.map { matchesResult($0, result) } == true }
                let directOK = direct.allSatisfy { conjunctMatches($0.tree, conditionAnchors, graph) }
                if (!producing.isEmpty || !direct.isEmpty) && guarded && directOK && producing.allSatisfy({ !$0.2.isEmpty }) {
                    add(.exclusivity, "only when", .RELATION_PROVEN, operands: [describe(conditionAnchors), result], op: "guarded return")
                } else { add(.exclusivity, "only when", .EXCLUSIVITY_UNPROVEN) }
            } else {
                // If C then R: a site with no earlier exit whose condition is implied by C and whose result is R.
                if let site = sites.first(where: { !$0.precededByExit && ($0.result.map { matchesResult($0, result) } ?? false)
                                                   && impliedBy($0.tree, conditionAnchors, graph) }) {
                    add(.implication, "IF condition THEN \(result)", .RELATION_PROVEN, operands: [describe(conditionAnchors), result],
                        op: site.operatorText, range: "\(site.node)@\(site.lines.lowerBound)")
                } else { add(.implication, "IF condition THEN \(result)", .RELATION_UNPROVEN) }
            }
        } else if has(exclusivity) {
            add(.exclusivity, "only (no condition part)", .UNSUPPORTED_SEMANTIC_OBLIGATION)
        }
        let presenceOnly = obligations.isEmpty && has(declaration) && wholeAnchors.literals.isEmpty && wholeAnchors.comparisons.isEmpty
        if obligations.isEmpty && !presenceOnly {
            add(.unsupported, "behaviour not machine-classifiable", .UNSUPPORTED_SEMANTIC_OBLIGATION)
        }
        return finish(obligations, proof: proof, presenceOnly: presenceOnly, sites: sites.count)
    }

    static func finish(_ obligations: [SemanticObligation], proof: VerifierProofObligationsF.ClauseProof, presenceOnly: Bool, sites: Int) -> Result {
        let allProven = !obligations.isEmpty && obligations.allSatisfy { $0.resolutionStatus == .RELATION_PROVEN }
        let strength: Strength = presenceOnly
            ? (Strength(rawValue: proof.proofStrength.rawValue) ?? .PRESENCE)
            : allProven ? .RELATION_PROVEN : .SEMANTIC_REQUIREMENT_UNPROVEN
        return .init(obligations: obligations, presenceOnlyClause: presenceOnly, strength: strength, passes: presenceOnly || allProven, sitesExamined: sites)
    }

    // MARK: structure matching

    static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
    static func describe(_ a: Anchors) -> String {
        (a.comparisons.map { "\($0.0) \(fmt($0.1))" } + a.cases.map { "." + $0 } + a.identifiers.sorted() + a.literals.sorted()).joined(separator: ",")
    }
    static func resultToken(_ a: Anchors) -> String? {
        if a.cases.count == 1 { return "." + a.cases.first! }
        let literals = a.literals.filter { ["true", "false", "nil"].contains($0) }
        return literals.count == 1 && a.cases.isEmpty ? literals.first : nil
    }
    static func matchesResult(_ expression: String, _ result: String) -> Bool {
        expression.trimmingCharacters(in: .whitespaces) == result
    }
    static func find(_ sites: [CS.Site], where test: (String, CS.Atom) -> Bool) -> (CS.Site, CS.Atom)? {
        for site in sites { if let atom = positiveAtoms(site.tree).first(where: { test(site.node, $0) }) { return (site, atom) } }
        return nil
    }
    static func positiveAtoms(_ tree: CS.Tree) -> [CS.Atom] {
        switch tree {
        case .atom(let a): return [a]
        case .and(let kids), .or(let kids): return kids.flatMap(positiveAtoms)
        case .not: return []
        }
    }
    static func value(_ side: String?, graph: VerifierRelationGraphF, node: String) -> Double? {
        guard let side = side?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let n = Double(side) { return n }
        let name = side.split(separator: ".").last.map(String.init) ?? side
        let targets = graph.edges.filter { $0.from == node && graph.terminalNames[$0.to] == name }.map(\.to)
        guard Set(targets).count == 1 else { return nil }
        return graph.constantValues[targets[0]].flatMap(Double.init)
    }
    static let mirror = ["<": ">", ">": "<", "<=": ">=", ">=": "<=", "==": "==", "!=": "!="]
    static func compares(_ atom: CS.Atom, op: String, value v: Double, graph: VerifierRelationGraphF, node: String) -> Bool {
        guard let o = atom.op else { return false }
        return (o == op && value(atom.rhs, graph: graph, node: node) == v) || (mirror[o] == op && value(atom.lhs, graph: graph, node: node) == v)
    }
    /// An atom matches an operand if it carries the operand's key anchors: all comparisons, else all enum
    /// cases, else at least one identifier.
    static func atomMatches(_ atom: CS.Atom, _ a: Anchors, _ graph: VerifierRelationGraphF) -> Bool {
        let words = Set(atom.text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init))
        if !a.comparisons.isEmpty {
            return a.comparisons.allSatisfy { c in
                guard let o = atom.op else { return false }
                let direct = o == c.0 && (Double(atom.rhs?.trimmingCharacters(in: .whitespaces) ?? "") == c.1)
                let mirrored = mirror[o] == c.0 && (Double(atom.lhs?.trimmingCharacters(in: .whitespaces) ?? "") == c.1)
                return direct || mirrored || graph.nodes.contains { n in
                    (graph.constantValues[n.id].flatMap(Double.init) == c.1) && words.contains(graph.terminalNames[n.id] ?? "") && (o == c.0 || mirror[o] == c.0)
                }
            }
        }
        if !a.cases.isEmpty { return a.cases.allSatisfy { atom.text.contains("." + $0) } && (atom.op == nil || atom.op == "==") }
        return !a.identifiers.isEmpty && !a.identifiers.isDisjoint(with: words) && atom.op != "!="
    }
    static func subtreeMatches(_ tree: CS.Tree, _ a: Anchors, _ graph: VerifierRelationGraphF) -> Bool {
        positiveAtoms(tree).contains { atomMatches($0, a, graph) }
    }
    static func chainHas(_ tree: CS.Tree, _ kind: String, _ left: Anchors, _ right: Anchors, _ graph: VerifierRelationGraphF) -> Bool {
        let kids: [CS.Tree]
        switch (tree, kind) { case (.and(let k), "and"): kids = k; case (.or(let k), "or"): kids = k; default: return false }
        for (i, x) in kids.enumerated() where subtreeMatches(x, left, graph) {
            for (j, y) in kids.enumerated() where j != i && subtreeMatches(y, right, graph) { return true }
        }
        return false
    }
    /// Condition anchors C imply the site condition T: some top-level disjunct of T consists only of
    /// conjuncts that are positive atoms matched by C's anchors.
    static func impliedBy(_ tree: CS.Tree, _ c: Anchors, _ graph: VerifierRelationGraphF) -> Bool {
        let disjuncts: [CS.Tree]; if case .or(let k) = tree { disjuncts = k } else { disjuncts = [tree] }
        return disjuncts.contains { d in
            let conjuncts: [CS.Tree]; if case .and(let k) = d { conjuncts = k } else { conjuncts = [d] }
            return conjuncts.allSatisfy { if case .atom(let a) = $0 { return atomMatchesAny(a, c, graph) }; return false }
        }
    }
    static func atomMatchesAny(_ atom: CS.Atom, _ c: Anchors, _ graph: VerifierRelationGraphF) -> Bool {
        let singles = c.comparisons.map { Anchors(comparisons: [$0], cases: [], identifiers: [], literals: []) }
            + c.cases.map { Anchors(comparisons: [], cases: [$0], identifiers: [], literals: []) }
            + c.identifiers.map { Anchors(comparisons: [], cases: [], identifiers: [$0], literals: []) }
        return singles.contains { atomMatches(atom, $0, graph) }
    }
    /// C appears as a top-level conjunct (positive) of the tree: the tree can only hold when C holds.
    static func conjunctMatches(_ tree: CS.Tree, _ c: Anchors, _ graph: VerifierRelationGraphF) -> Bool {
        let conjuncts: [CS.Tree]; if case .and(let k) = tree { conjuncts = k } else { conjuncts = [tree] }
        return conjuncts.contains { if case .atom(let a) = $0 { return atomMatchesAny(a, c, graph) }; return false }
    }
}
