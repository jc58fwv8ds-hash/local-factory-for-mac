import Foundation

extension VerifierRelationGraphF {
    public struct Expansion: Sendable {
        public let root: String
        public let depths: [String: Int]
        public let parents: [String: Edge]
        public let edges: [Edge]
        /// Behaviour edges not followed because of a bound, with the line they start from.
        public let outOfBound: [Attempt]
    }

    static func line(of edge: Edge) -> Int? {
        edge.deterministicReason.components(separatedBy: "token line ").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Same BFS and bounds as Arm E. Differences: node-level diagnostics are NOT turned into
    /// proof-wide gaps here (the prover scopes them to the evidence path), and a BFS parent edge is
    /// kept per node so the prover can reconstruct the exact path it relies on.
    public func expand(rootID: String, bounds: P.Bounds = .phase3) -> Expansion {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let outgoing = Dictionary(grouping: edges, by: \.from)
        var depths = [rootID: 0], parents: [String: Edge] = [:], files: Set<String> = [byID[rootID]?.file ?? ""]
        var queue = [rootID], cursor = 0, selected: [Edge] = [], out: [Attempt] = []
        while cursor < queue.count {
            let from = queue[cursor]; cursor += 1
            for edge in outgoing[from] ?? [] {
                guard let target = byID[edge.to] else { continue }
                func exceeded(_ gap: String) {
                    guard VerifierRelationGraphE.behaviour.contains(edge.relationType) else { return }
                    out.append(.init(id: "\(from)>\(edge.to):\(gap)", from: from, target: edge.to, resolutionStatus: .OUT_OF_BOUND,
                                     reason: gap, line: Self.line(of: edge)))
                }
                if depths[target.id] == nil {
                    guard depths[from]! < bounds.depth else { exceeded("depthBound"); continue }
                    guard depths.count < bounds.nodes else { exceeded("nodeBound"); continue }
                    guard files.contains(target.file) || files.count < bounds.additionalFiles + 1 else { exceeded("fileBound"); continue }
                }
                guard selected.count < bounds.edges else { exceeded("edgeBound"); continue }
                selected.append(edge)
                if depths[target.id] == nil {
                    depths[target.id] = depths[from]! + 1; parents[target.id] = edge; files.insert(target.file); queue.append(target.id)
                }
            }
        }
        return .init(root: rootID, depths: depths, parents: parents, edges: selected, outOfBound: out)
    }
}
