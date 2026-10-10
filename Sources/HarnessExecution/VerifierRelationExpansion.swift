import Foundation

extension VerifierRelationIndex {
    public struct Expansion: Sendable {
        public let nodes: [P.Node]
        public let edges: [P.Edge]
        public let maximumDepth: Int
        public let gaps: [String]
        public var complete: Bool { gaps.isEmpty }
    }

    /// This step follows only indexed relations. Reaching a bound leaves a gap; it never
    /// increases the bound to make a requirement look supported.
    public func expand(rootSymbol: String) -> Expansion {
        let roots = nodes.filter { $0.symbol == rootSymbol }
        guard roots.count == 1, let root = roots.first else {
            return .init(nodes: [], edges: [], maximumDepth: 0, gaps: ["missingOrAmbiguousRoot"])
        }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let outgoing = Dictionary(grouping: edges, by: \.from)
        var depths = [root.id: 0], files: Set<String> = [root.file], queue = [root.id]
        var selected: [P.Edge] = [], cursor = 0, gaps: [String] = []
        let bound = P.Bounds.phase3
        while cursor < queue.count {
            let from = queue[cursor]; cursor += 1
            // Only issues of visited nodes matter: an unresolved reference inside the proof path
            // means the path may continue somewhere we cannot see.
            gaps += (nodeDiagnostics[from] ?? []).map { "node:" + $0 }
            for edge in outgoing[from] ?? [] {
                guard let target = byID[edge.to] else { gaps.append("missingEndpoint"); continue }
                // Type references (signatures, annotations, conformances) carry no behaviour: beyond a
                // bound they are left out. Behaviour edges beyond a bound are a gap (proof incomplete).
                let behaviour: Set<P.Relation> = [.directCall, .helperCall, .memberAccess, .constantReference]
                func exceeded(_ gap: String) { if behaviour.contains(edge.relationType) { gaps.append(gap) } }
                if depths[target.id] == nil {
                    guard depths[from]! < bound.depth else { exceeded("depthBound"); continue }
                    guard depths.count < bound.nodes else { exceeded("nodeBound"); continue }
                    guard files.contains(target.file) || files.count < bound.additionalFiles + 1 else {
                        exceeded("fileBound"); continue
                    }
                }
                guard selected.count < bound.edges else { exceeded("edgeBound"); continue }
                selected.append(edge)
                if depths[target.id] == nil {
                    depths[target.id] = depths[from]! + 1; files.insert(target.file); queue.append(target.id)
                }
            }
        }
        return .init(nodes: nodes.filter { depths[$0.id] != nil }, edges: selected,
                     maximumDepth: depths.values.max() ?? 0, gaps: Array(Set(gaps)).sorted())
    }

    /// Supplies index-derived identities to the low-level graph checker. The caller still
    /// needs independently established clause roots; this method does not interpret clauses.
    public func validateGraph(_ bundle: P.Bundle, production: [String: String],
                              protectedPaths: Set<String>, clauseRootSymbols: Set<String>) -> P.GraphCheck {
        guard indexedProduction == Self.productionSources(production, protectedPaths: protectedPaths) else {
            return .init(valid: false, reasons: ["staleRelationIndex"], maximumDepth: 0, filesInspected: 0, contextBytes: 0)
        }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let relations = Set(edges.compactMap { edge -> P.RelationIdentity? in
            guard let from = byID[edge.from], let to = byID[edge.to] else { return nil }
            return .init(from: from, to: to, type: edge.relationType)
        })
        let checked = P.validateGraph(bundle, production: production, protectedPaths: protectedPaths,
            declarations: Set(nodes.map(P.NodeIdentity.init)), relations: relations,
            clauseRoots: Set(nodes.filter { clauseRootSymbols.contains($0.symbol) }.map(P.NodeIdentity.init)))
        let issues = bundle.evidenceNodes.flatMap { node in (nodeDiagnostics[node.id] ?? []).map { "node:" + $0 } }
        guard issues.isEmpty else {
            return .init(valid: false, reasons: checked.reasons + issues,
                         maximumDepth: checked.maximumDepth, filesInspected: checked.filesInspected,
                         contextBytes: checked.contextBytes)
        }
        return checked
    }
}
