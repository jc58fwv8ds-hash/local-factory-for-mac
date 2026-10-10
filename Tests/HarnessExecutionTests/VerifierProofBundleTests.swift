import Testing
@testable import HarnessExecution

struct VerifierProofBundleTests {
    typealias P = VerifierProofBundle

    func node(_ id: String, file: String? = nil, text: String? = nil) -> P.Node {
        .init(id: id, file: file ?? "Sources/\(id).swift", symbol: "Owner.\(id)",
              sourceRange: 0...0, exactText: text ?? "func \(id)() {}", evidenceType: "declaration")
    }

    func check(_ nodes: [P.Node], links: [(String, String)], support: [String],
               verified: Bool = true, protected: Set<String> = [], sourceOverride: [String: String]? = nil,
               claimed: RequirementVerification.Verdict = .UNCERTAIN) -> P.GraphCheck {
        let edges = links.map { P.Edge(from: $0.0, to: $0.1, relationType: .helperCall,
                                      deterministicReason: "resolved qualified declaration") }
        let bundle = P.Bundle(clauseID: "C1", proofObligations: [
            .init(id: "O1", kind: "requiredCall", rootNode: "entry", supportingNodes: support)
        ], evidenceNodes: nodes, relationEdges: edges, executionEvidence: [], contradictions: [],
                             unsupportedObligations: [], admission: claimed)
        let relations = Set(links.compactMap { a, b -> P.RelationIdentity? in
            guard let from = nodes.first(where: { $0.id == a }), let to = nodes.first(where: { $0.id == b }) else { return nil }
            return .init(from: from, to: to, type: .helperCall)
        })
        return P.validateGraph(bundle,
            production: sourceOverride ?? Dictionary(nodes.map { ($0.file, $0.exactText) }, uniquingKeysWith: { a, _ in a }),
            protectedPaths: protected, declarations: Set(nodes.map(P.NodeIdentity.init)),
            relations: verified ? relations : [],
            clauseRoots: Set(nodes.filter { $0.id == "entry" }.map(P.NodeIdentity.init)))
    }

    @Test func callerHelperConstantAcrossThreeFiles() {
        let result = check([node("entry"), node("helper"), node("constant")],
                           links: [("entry", "helper"), ("helper", "constant")], support: ["constant"])
        #expect(result.valid)
        #expect(result.maximumDepth == 2)
        #expect(result.filesInspected == 3)
    }

    @Test func unrelatedIdenticalLiteralIsNotProof() {
        let result = check([node("entry", text: "return 7"), node("unrelated", text: "return 7")],
                           links: [], support: ["unrelated"])
        #expect(!result.valid)
        #expect(result.reasons.contains("unrelatedEvidence:unrelated"))
    }

    @Test func unverifiedSameNamedMethodDoesNotCreateRelation() {
        let result = check([node("entry"), node("helper")], links: [("entry", "helper")],
                           support: ["helper"], verified: false)
        #expect(!result.valid)
        #expect(result.reasons.contains("unverifiedRelation:entry:helper"))
    }

    @Test func cycleTerminates() {
        let result = check([node("entry"), node("helper")],
                           links: [("entry", "helper"), ("helper", "entry")], support: ["helper"])
        #expect(result.valid)
        #expect(result.maximumDepth == 1)
    }

    @Test func depthThreeIsRejected() {
        let result = check([node("entry"), node("a"), node("b"), node("c")],
                           links: [("entry", "a"), ("a", "b"), ("b", "c")], support: ["c"])
        #expect(!result.valid)
        #expect(result.maximumDepth == 2)
    }

    @Test func fifthAdditionalFileIsRejected() {
        let names = ["a", "b", "c", "d", "e"]
        let result = check([node("entry")] + names.map { node($0) },
                           links: names.map { ("entry", $0) }, support: names)
        #expect(!result.valid)
        #expect(result.reasons.contains("fileBound"))
    }

    @Test func protectedEvidenceIsRejected() {
        let helper = node("helper")
        #expect(!check([node("entry"), helper], links: [("entry", "helper")],
                       support: ["helper"], protected: [helper.file]).valid)
    }

    @Test func staleSourceIsRejected() {
        let entry = node("entry")
        #expect(!check([entry], links: [], support: ["entry"],
                       sourceOverride: [entry.file: "func entry() { fatalError() }"]).valid)
    }

    @Test func claimedAdmissionCannotRepairMissingRelation() {
        #expect(!check([node("entry"), node("helper")], links: [], support: ["helper"],
                       claimed: .SATISFIED).valid)
    }

    @Test func deterministicRepeatedResults() {
        let nodes = [node("entry"), node("helper")]
        let first = check(nodes, links: [("entry", "helper")], support: ["helper"])
        #expect(first == check(nodes.reversed(), links: [("entry", "helper")], support: ["helper"]))
    }

    @Test func missingEndpointAndEmptyProofFailClosed() {
        #expect(!check([node("entry")], links: [("entry", "missing")], support: ["missing"]).valid)
        #expect(!check([node("entry")], links: [], support: []).valid)
    }

    @Test func relationIdentityIncludesOwnerAndFile() {
        let first = P.Node(id: "a", file: "Sources/A.swift", symbol: "First.run",
                           sourceRange: 0...0, exactText: "func run() {}", evidenceType: "declaration")
        let second = P.Node(id: "b", file: "Sources/B.swift", symbol: "Second.run",
                            sourceRange: 0...0, exactText: "func run() {}", evidenceType: "declaration")
        let root = node("entry")
        #expect(P.RelationIdentity(from: root, to: first, type: .directCall)
                != P.RelationIdentity(from: root, to: second, type: .directCall))
    }

    @Test func oversizedAndDuplicateNodesAreRejectedWithoutTrap() {
        let names = (0..<12).map { "n\($0)" }
        #expect(!check([node("entry")] + names.map { node($0) },
                       links: names.map { ("entry", $0) }, support: names).valid)
        #expect(!check([node("entry"), node("entry")], links: [], support: ["entry"]).valid)
    }
}
