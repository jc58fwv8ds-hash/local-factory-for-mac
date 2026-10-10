import Foundation

/// Arm D's evidence transport. A bundle is a claim, not an authorization or a proof.
/// In particular, decoding `admission: SATISFIED` never admits task completion.
public enum VerifierProofBundle {
    public enum Relation: String, Codable, Sendable {
        case declaration, referenceUse, directCall, memberAccess, parameterType, returnType
        case constantReference, helperCall, protocolConformance, dependency
    }

    public struct Node: Codable, Equatable, Sendable {
        public let id: String
        public let file: String
        public let symbol: String
        /// Zero-based, inclusive line bounds in the original, unnormalized source.
        public let sourceRange: ClosedRange<Int>
        public let exactText: String
        public let evidenceType: String
    }

    public struct Edge: Codable, Equatable, Sendable {
        public let from: String
        public let to: String
        public let relationType: Relation
        public let deterministicReason: String
    }

    public struct Obligation: Codable, Equatable, Sendable {
        public let id: String
        public let kind: String
        public let rootNode: String
        public let supportingNodes: [String]
    }

    public struct Bundle: Codable, Equatable, Sendable {
        public let clauseID: String
        public let proofObligations: [Obligation]
        public let evidenceNodes: [Node]
        public let relationEdges: [Edge]
        /// References only. Receipt contents must be loaded from Harness-owned storage.
        public let executionEvidence: [String]
        public let contradictions: [String]
        public let unsupportedObligations: [String]
        public let admission: RequirementVerification.Verdict
    }

    public struct Bounds: Equatable, Sendable {
        public let depth: Int
        public let additionalFiles: Int
        public let nodes: Int
        public let edges: Int
        public static let phase3 = Bounds(depth: 2, additionalFiles: 4, nodes: 12, edges: 16)
    }

    /// Identity deliberately includes file and source range. Same-named methods in different
    /// types/files must not acquire an edge merely because their terminal names match.
    public struct NodeIdentity: Hashable, Sendable {
        public let file: String
        public let symbol: String
        public let sourceRange: ClosedRange<Int>
        public init(_ node: Node) {
            file = node.file; symbol = node.symbol; sourceRange = node.sourceRange
        }
    }

    public struct RelationIdentity: Hashable, Sendable {
        public let from: NodeIdentity
        public let to: NodeIdentity
        public let type: Relation
        public init(from: Node, to: Node, type: Relation) {
            self.from = NodeIdentity(from); self.to = NodeIdentity(to); self.type = type
        }
    }

    /// Structural validation only: this is NOT Requirement Verification SATISFIED.
    public struct GraphCheck: Equatable, Sendable {
        public let valid: Bool
        public let reasons: [String]
        public let maximumDepth: Int
        public let filesInspected: Int
        public let contextBytes: Int
    }

    /// `declarations`, `relations` and `clauseRoots` must come from a deterministic production
    /// index, never from bundle JSON, fixture labels, model claims or protected tests.
    /// Text matching alone is insufficient: the exact qualified declaration and edge must
    /// both have been resolved by that index. Unknown/ambiguous edges fail closed.
    public static func validateGraph(
        _ bundle: Bundle,
        production: [String: String],
        protectedPaths: Set<String>,
        declarations: Set<NodeIdentity>,
        relations: Set<RelationIdentity>,
        clauseRoots: Set<NodeIdentity>,
        bounds: Bounds = .phase3
    ) -> GraphCheck {
        var reasons: [String] = []
        var maximumDepth = 0
        let files = Set(bundle.evidenceNodes.map(\.file))
        let bytes = bundle.evidenceNodes.reduce(0) { $0 + $1.exactText.utf8.count }
        func result() -> GraphCheck {
            .init(valid: reasons.isEmpty, reasons: reasons.sorted(), maximumDepth: maximumDepth,
                  filesInspected: files.count, contextBytes: bytes)
        }
        guard bounds.depth >= 0, bounds.depth <= 2, bounds.additionalFiles >= 0,
              bounds.additionalFiles <= 4, bounds.nodes > 0, bounds.nodes <= 12,
              bounds.edges >= 0, bounds.edges <= 16 else {
            reasons.append("invalidBounds"); return result()
        }
        guard !bundle.evidenceNodes.isEmpty, bundle.evidenceNodes.count <= bounds.nodes,
              bundle.relationEdges.count <= bounds.edges,
              !bundle.proofObligations.isEmpty, bundle.proofObligations.count <= bounds.nodes else {
            reasons.append("emptyOrOverBound"); return result()
        }
        let ids = bundle.evidenceNodes.map(\.id)
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count,
              Set(bundle.proofObligations.map(\.id)).count == bundle.proofObligations.count else {
            reasons.append("duplicateOrEmptyIdentity"); return result()
        }
        let nodes = Dictionary(uniqueKeysWithValues: bundle.evidenceNodes.map { ($0.id, $0) })
        for node in bundle.evidenceNodes {
            let components = node.file.split(separator: "/", omittingEmptySubsequences: false)
            guard !node.file.hasPrefix("/"),
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !components.contains(where: { $0 == "Tests" || $0 == "UITests" }),
                  !protectedPaths.contains(node.file), let source = production[node.file] else {
                reasons.append("nonProductionNode:\(node.id)"); continue
            }
            let lines = source.components(separatedBy: "\n")
            guard node.sourceRange.lowerBound >= 0, node.sourceRange.upperBound < lines.count,
                  !node.exactText.isEmpty,
                  lines[node.sourceRange].joined(separator: "\n") == node.exactText else {
                reasons.append("sourceMismatch:\(node.id)"); continue
            }
            if !declarations.contains(NodeIdentity(node)) {
                reasons.append("unresolvedDeclaration:\(node.id)")
            }
        }
        var adjacency: [String: Set<String>] = [:]
        var seenEdges: Set<RelationIdentity> = []
        for edge in bundle.relationEdges {
            guard let from = nodes[edge.from], let to = nodes[edge.to] else {
                reasons.append("missingEndpoint"); continue
            }
            let identity = RelationIdentity(from: from, to: to, type: edge.relationType)
            guard relations.contains(identity), !edge.deterministicReason.isEmpty else {
                reasons.append("unverifiedRelation:\(edge.from):\(edge.to)"); continue
            }
            guard seenEdges.insert(identity).inserted else {
                reasons.append("duplicateRelation"); continue
            }
            adjacency[edge.from, default: []].insert(edge.to)
        }
        let roots = Set(bundle.proofObligations.map(\.rootNode))
        let rootFiles = Set(roots.compactMap { nodes[$0]?.file })
        if files.subtracting(rootFiles).count > bounds.additionalFiles {
            reasons.append("fileBound")
        }
        var used: Set<String> = []
        for obligation in bundle.proofObligations {
            guard !obligation.id.isEmpty, let root = nodes[obligation.rootNode],
                  clauseRoots.contains(NodeIdentity(root)) else {
                reasons.append("unanchoredObligation:\(obligation.id)"); continue
            }
            // Per-root BFS: cycles terminate and another clause root cannot shorten this path.
            var depths = [obligation.rootNode: 0]
            var queue = [obligation.rootNode]
            var cursor = 0
            while cursor < queue.count {
                let current = queue[cursor]; cursor += 1
                let depth = depths[current]!
                guard depth < bounds.depth else { continue }
                for next in (adjacency[current] ?? []).sorted() where depths[next] == nil {
                    depths[next] = depth + 1; queue.append(next)
                }
            }
            used.formUnion(depths.keys)
            maximumDepth = max(maximumDepth, depths.values.max() ?? 0)
            if obligation.supportingNodes.isEmpty {
                reasons.append("unsupportedObligation:\(obligation.id)")
            }
            for support in obligation.supportingNodes where depths[support] == nil {
                reasons.append("unreachableEvidence:\(obligation.id):\(support)")
            }
        }
        for id in Set(ids).subtracting(used).sorted() { reasons.append("unrelatedEvidence:\(id)") }
        return result()
    }
}
