import Foundation

extension VerifierRelationGraphE {
    // MARK: bounded expansion

    public struct Expansion: Sendable {
        public let root: String
        public let depths: [String: Int]
        public let edges: [Edge]
        public let outOfBound: [Attempt]
        public let gaps: [String]
    }

    static let behaviour: Set<P.Relation> = [.directCall, .helperCall, .memberAccess, .constantReference]

    /// Per-root BFS with the Phase 3 bounds. Behaviour edges beyond a bound are recorded as
    /// OUT_OF_BOUND gaps; type/declaration edges beyond a bound are omitted.
    public func expand(rootID: String, bounds: P.Bounds = .phase3) -> Expansion {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let outgoing = Dictionary(grouping: edges, by: \.from)
        var depths = [rootID: 0], files: Set<String> = [byID[rootID]?.file ?? ""], queue = [rootID], cursor = 0
        var selected: [Edge] = [], out: [Attempt] = [], gaps: [String] = []
        while cursor < queue.count {
            let from = queue[cursor]; cursor += 1
            gaps += (nodeDiagnostics[from] ?? []).map { "node:" + $0 }
            for edge in outgoing[from] ?? [] {
                guard let target = byID[edge.to] else { gaps.append("missingEndpoint"); continue }
                func exceeded(_ gap: String) {
                    out.append(.init(from: from, target: edge.to, resolutionStatus: .OUT_OF_BOUND, reason: gap))
                    if Self.behaviour.contains(edge.relationType) { gaps.append(gap) }
                }
                if depths[target.id] == nil {
                    guard depths[from]! < bounds.depth else { exceeded("depthBound"); continue }
                    guard depths.count < bounds.nodes else { exceeded("nodeBound"); continue }
                    guard files.contains(target.file) || files.count < bounds.additionalFiles + 1 else { exceeded("fileBound"); continue }
                }
                guard selected.count < bounds.edges else { exceeded("edgeBound"); continue }
                selected.append(edge)
                if depths[target.id] == nil { depths[target.id] = depths[from]! + 1; files.insert(target.file); queue.append(target.id) }
            }
        }
        return .init(root: rootID, depths: depths, edges: selected, outOfBound: out, gaps: Array(Set(gaps)).sorted())
    }
}
