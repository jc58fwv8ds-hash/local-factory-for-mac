import Testing
@testable import HarnessExecution

struct VerifierRelationIndexTests {
    let caller = """
    enum Entry {
        static func run() -> Int {
            return Helper.value()
        }
    }
    """
    let helper = """
    enum Helper {
        static func value() -> Int {
            return Limits.floor
        }
    }
    """
    let constant = """
    enum Limits {
        static let floor = 7
    }
    """
    func sources() -> [String: String] {
        ["Sources/Entry.swift": caller, "Sources/Helper.swift": helper, "Sources/Limits.swift": constant]
    }
    func members(_ index: VerifierRelationIndex) -> [VerifierProofBundle.Node] {
        index.nodes.filter { $0.evidenceType != "typeDeclaration" }
    }
    func relationNames(_ index: VerifierRelationIndex) -> [String] {
        let names = Dictionary(uniqueKeysWithValues: index.nodes.map { ($0.id, $0.symbol) })
        return index.edges.map { "\(names[$0.from]!)→\(names[$0.to]!):\($0.relationType.rawValue)" }
    }

    @Test func callerHelperConstantAcrossFiles() {
        let index = VerifierRelationIndex(production: sources(), protectedPaths: [])
        #expect(members(index).count == 3)
        #expect(index.diagnostics.isEmpty)
        #expect(relationNames(index) == ["Entry.run→Helper.value:directCall", "Helper.value→Limits.floor:constantReference"])
    }

    @Test func commentsStringsAndUnrelatedLiteralDoNotCreateEdges() {
        var files = sources()
        files["Sources/Entry.swift"] = """
        enum Entry {
            static func run() -> Int {
                // Helper.value()
                let message = "Helper.value()"
                /* nested /* Helper.value() */ comment */
                return 7
            }
        }
        """
        let index = VerifierRelationIndex(production: files, protectedPaths: [])
        #expect(!relationNames(index).contains(where: { $0.hasPrefix("Entry.run→") }))
    }

    @Test func sameMethodInAnotherTypeIsNotSelected() {
        var files = sources()
        files["Sources/Other.swift"] = helper.replacingOccurrences(of: "Helper", with: "Other")
        let index = VerifierRelationIndex(production: files, protectedPaths: [])
        #expect(relationNames(index).contains("Entry.run→Helper.value:directCall"))
        #expect(!relationNames(index).contains("Entry.run→Other.value:directCall"))
    }

    @Test func overloadsAndExtensionsRemainUnresolved() {
        var files = sources()
        files["Sources/Helper.swift"] = """
        enum Helper {
            static func value() -> Int { return 7 }
            static func value(_ x: Int) -> Int { return x }
        }
        """
        #expect(!VerifierRelationIndex(production: files, protectedPaths: []).nodes.contains { $0.symbol == "Helper.value" })
        files = sources()
        files["Sources/Extra.swift"] = "extension Helper {}"
        #expect(!VerifierRelationIndex(production: files, protectedPaths: []).nodes.contains { $0.symbol == "Helper.value" })
    }

    @Test func parameterShadowIsNotTypeReference() {
        var files = sources()
        files["Sources/Entry.swift"] = caller.replacingOccurrences(of: "run()", with: "run(Helper: SomeOtherType)")
        #expect(!relationNames(VerifierRelationIndex(production: files, protectedPaths: [])).contains { $0.hasPrefix("Entry.run→") })
    }

    @Test func closureAndTupleShadowAreNotGuessed() {
        for body in ["let (Helper, x) = pair\nreturn Helper.value()", "return values.map { Helper in Helper.value() }.count"] {
            var files = sources()
            files["Sources/Entry.swift"] = caller.replacingOccurrences(of: "return Helper.value()", with: body)
            let index = VerifierRelationIndex(production: files, protectedPaths: [])
            #expect(!relationNames(index).contains { $0.hasPrefix("Entry.run→") })
            #expect(index.diagnostics.contains("unsupportedLocalBinding:Entry.run"))
        }
    }

    @Test func protectedSourcesNeverSupplyDeclarations() {
        #expect(members(VerifierRelationIndex(production: sources(), protectedPaths: ["Sources/Helper.swift"])).count == 2)
        #expect(VerifierRelationIndex(production: ["Tests/Fake.swift": helper], protectedPaths: []).nodes.isEmpty)
    }

    @Test func lexicalFailureAndIncompleteConstantFailClosed() {
        for source in ["enum A {\nstatic let x\n}", "enum A {", "#if DEBUG\n" + helper + "\n#endif"] {
            #expect(members(VerifierRelationIndex(production: ["Sources/Bad.swift": source], protectedPaths: [])).isEmpty)
        }
    }

    @Test func deterministicOrderAndExactRanges() {
        let a = VerifierRelationIndex(production: sources(), protectedPaths: [])
        let b = VerifierRelationIndex(production: Dictionary(sources().reversed(), uniquingKeysWith: { a, _ in a }), protectedPaths: [])
        #expect(a.nodes == b.nodes)
        #expect(a.edges == b.edges)
        for node in a.nodes {
            #expect(node.exactText == sources()[node.file]!.components(separatedBy: "\n")[node.sourceRange].joined(separator: "\n"))
        }
    }

    @Test func expansionConnectsToGraphCheckWithoutModelRelations() throws {
        let index = VerifierRelationIndex(production: sources(), protectedPaths: [])
        let expansion = index.expand(rootSymbol: "Entry.run")
        #expect(expansion.complete)
        #expect(expansion.maximumDepth == 2)
        let root = try #require(expansion.nodes.first { $0.symbol == "Entry.run" })
        let leaf = try #require(expansion.nodes.first { $0.symbol == "Limits.floor" })
        let bundle = VerifierProofBundle.Bundle(clauseID: "C1", proofObligations: [
            .init(id: "O1", kind: "reachableConstant", rootNode: root.id, supportingNodes: [leaf.id])
        ], evidenceNodes: expansion.nodes, relationEdges: expansion.edges, executionEvidence: [],
            contradictions: [], unsupportedObligations: [], admission: .UNCERTAIN)
        #expect(index.validateGraph(bundle, production: sources(), protectedPaths: [],
                                   clauseRootSymbols: ["Entry.run"]).valid)
        #expect(!index.validateGraph(bundle, production: sources(), protectedPaths: [],
                                    clauseRootSymbols: ["Unrelated.run"]).valid)
        var changed = sources()
        changed["Sources/Entry.swift"] = caller.replacingOccurrences(of: "Helper.value()", with: "Other.value()")
        #expect(index.validateGraph(bundle, production: changed, protectedPaths: [],
                                   clauseRootSymbols: ["Entry.run"]).reasons == ["staleRelationIndex"])
    }

    @Test func depthBoundaryAndCyclesRemainBounded() {
        var files = sources()
        files["Sources/Limits.swift"] = """
        enum Limits {
            static let floor = FarAway.value
        }
        """
        files["Sources/FarAway.swift"] = """
        enum FarAway {
            static let value = 7
        }
        """
        let deep = VerifierRelationIndex(production: files, protectedPaths: []).expand(rootSymbol: "Entry.run")
        #expect(deep.maximumDepth == 2)
        #expect(deep.gaps.contains("depthBound"))
        #expect(deep.nodes.count == 3)
        files = sources()
        files["Sources/Helper.swift"] = helper.replacingOccurrences(of: "Limits.floor", with: "Entry.run()")
        let cycle = VerifierRelationIndex(production: files, protectedPaths: []).expand(rootSymbol: "Entry.run")
        #expect(cycle.complete)
        #expect(cycle.nodes.count == 2)
        #expect(cycle.edges.count == 2)
    }
}
