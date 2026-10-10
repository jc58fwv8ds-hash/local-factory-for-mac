import Foundation
import HarnessCore
import Testing
@testable import HarnessExecution

@Suite struct RepositorySymbolIndexTests {
    let files = [
        "Sources/Store/Vault.swift": "import Foundation\nstruct TokenVault { var cached_value: Int = 0; func refreshCache() {} }",
        "Sources/Store/Operations.swift": "func lookup_entry(_ key: String) -> Int? { nil }",
        "Sources/Other/Duplicate.swift": "func lookup_entry(_ key: String) -> Int? { 1 }",
        "Sources/Store/OddName.swift": "enum DeliveryPhase { case waiting, delivered }",
        "Tests/StoreTests/Behavior.swift": "import Testing\n@Test func refreshCachePreservesValue() {}"
    ]

    @Test func objectiveWithoutFileButExactSymbolFindsDeclaration() {
        let s = select("refreshCache を呼ぶと保存値を維持するようにして")
        #expect(s.targets == ["Sources/Store/Vault.swift"])
        #expect(s.initialCandidates.first?.symbol == "refreshCache")
    }

    @Test func camelCaseSnakeCaseAndPascalCaseSplitIntoGeneralSubtokens() {
        #expect(RepositorySymbolIndex.subtokens("DevicePreparationParser") == ["device", "preparation", "parser"])
        #expect(RepositorySymbolIndex.subtokens("refreshCache") == ["refresh", "cache"])
        #expect(RepositorySymbolIndex.subtokens("cached_value") == ["cached", "value"])
        #expect(RepositorySymbolIndex.subtokens("network.clientState") == ["network", "client", "state"])
    }

    @Test func camelAndSnakeIdentifiersResolveDeclarationFiles() {
        #expect(select("refreshCache を安全にして").targets == ["Sources/Store/Vault.swift"])
        let snake = select("lookup_entry の空結果を扱って")
        #expect(snake.initialCandidates.filter { $0.symbol == "lookup_entry" }.map(\.file)
            == ["Sources/Other/Duplicate.swift", "Sources/Store/Operations.swift"])
    }

    @Test func symbolNameMayDifferFromFileName() {
        #expect(select("DeliveryPhase に失敗状態を追加して").targets == ["Sources/Store/OddName.swift"])
    }

    @Test func duplicateSymbolsHaveDeterministicOrdering() {
        let clauses = ObjectiveClauses.segment("lookup_entry を変更して")
        let index = RepositorySymbolIndex(sources: Dictionary(uniqueKeysWithValues: files.reversed()))
        let expected = index.retrieve(clauses: clauses)
        for _ in 0..<5 { #expect(index.retrieve(clauses: clauses) == expected) }
        #expect(expected.filter { $0.symbol == "lookup_entry" }.map(\.file)
            == ["Sources/Other/Duplicate.swift", "Sources/Store/Operations.swift"])
    }

    @Test func noInitialCandidateRequestsOneDiscoveryCycle() {
        let s = select("一覧の順番を自然にして")
        #expect(s.targets.isEmpty && s.needsTargetDiscovery)
        var budget = TargetDiscoveryPolicy.Budget()
        let first = budget.consume(), second = budget.consume()
        #expect(first)
        #expect(!second)
    }

    @Test func boundedSearchReturnsAtMostFiveReadOnlyCandidates() {
        let clauses = ObjectiveClauses.segment("一覧の順番を自然にして")
        let found = RepositorySymbolIndex(sources: files).retrieve(clauses: clauses,
            searchTerms: ["lookup_entry"], maximumFiles: TargetDiscoveryPolicy.maximumFiles)
        #expect(found.count == 2)
        #expect(select("一覧の順番を自然にして").targets.isEmpty)
    }

    @Test func nonexistentSymbolAndUnrelatedClauseCannotPromote() {
        let clauses = ObjectiveClauses.segment("一覧の順番を自然にして")
        let item = RequirementCoveragePlan.Item(requirement: "sort", source_clause_ids: [clauses[0].clauseID],
            relevant_symbols: ["Imaginary"], editable_targets: ["Sources/Store/Vault.swift"],
            read_only_evidence: [], rationale: "model assertion", coverage: "complete")
        let fake = RepositorySymbolIndex.Match(file: "Sources/Store/Vault.swift", symbol: "Imaginary",
            clauseID: clauses[0].clauseID, clauseText: clauses[0].exactSourceText,
            evidenceType: "exact_identifier_declaration", score: 100, reason: "claimed")
        #expect(TargetDiscoveryPolicy.promotionEvidence(file: fake.file,
            plan: .init(requirements: [item]), candidates: [fake], sources: files) == nil)
        let real = RepositorySymbolIndex(sources: files).retrieve(clauses: clauses,
            searchTerms: ["refreshCache"]).first { $0.symbol == "refreshCache" }!
        let wrongClause = RequirementCoveragePlan.Item(requirement: "sort", source_clause_ids: ["C999"],
            relevant_symbols: [real.symbol], editable_targets: [real.file], read_only_evidence: [],
            rationale: "wrong clause", coverage: "complete")
        #expect(TargetDiscoveryPolicy.promotionEvidence(file: real.file,
            plan: .init(requirements: [wrongClause]), candidates: [real], sources: files) == nil)
    }

    @Test func validatedRequirementPromotesOnlyExistingDiscoveredSymbol() {
        let clauses = ObjectiveClauses.segment("一覧の順番を自然にして")
        let match = RepositorySymbolIndex(sources: files).retrieve(clauses: clauses,
            searchTerms: ["refreshCache"]).first { $0.symbol == "refreshCache" }!
        let item = RequirementCoveragePlan.Item(requirement: "refresh", source_clause_ids: [match.clauseID],
            relevant_symbols: [match.symbol], editable_targets: [match.file], read_only_evidence: [],
            rationale: "declaration implements requested behavior", coverage: "complete")
        let evidence = TargetDiscoveryPolicy.promotionEvidence(file: match.file,
            plan: .init(requirements: [item]), candidates: [match], sources: files)
        #expect(evidence?.contains(where: { $0.contains("validated discovery symbol") }) == true)
    }

    @Test func testsAndImportsAreIndexedWithoutBecomingEditable() {
        let index = RepositorySymbolIndex(sources: files)
        #expect(index.symbols.contains { $0.file.contains("Tests/") && $0.kind == .test })
        #expect(index.symbols.contains { $0.name == "Foundation" && $0.kind == .importName })
        #expect(index.symbols.contains { $0.name == "refreshCache" && $0.kind == .method })
        #expect(index.symbols.contains { $0.name == "delivered" && $0.kind == .enumerationCase })
        let s = select("refreshCache を安全にして")
        #expect(!s.targets.contains { $0.contains("Tests/") })
    }

    @Test func repeatedSelectionIsIdentical() {
        let a = select("DeliveryPhase に失敗状態を追加して")
        for _ in 0..<5 {
            let b = select("DeliveryPhase に失敗状態を追加して", order: files.keys.shuffled())
            #expect(a.targets == b.targets && a.initialCandidates == b.initialCandidates)
        }
    }

    @Test func boundedDiscoverySnippetIsStableAndContainsMatchedSymbol() {
        let source = String(repeating: "prefix\n", count: 900)
            + "public func wantedTarget() {}\n"
            + String(repeating: "suffix\n", count: 900)
        let first = TargetDiscoveryPolicy.boundedSnippet(source: source,
            symbol: "wantedTarget", maximumCharacters: 300)
        let second = TargetDiscoveryPolicy.boundedSnippet(source: source,
            symbol: "wantedTarget", maximumCharacters: 300)
        #expect(first == second)
        #expect(first.contains("wantedTarget"))
        #expect(first.count <= 380)
        #expect(first != source)
    }

    @Test func discoveryRequestRejectsInventedFilePaths() {
        let valid = TargetDiscoveryRequest(search_terms: ["delivery", "queueState"],
            expected_symbol_kind: "method", expected_behavior: "removes delivered items",
            why_needed: "no confident initial target")
        #expect((try? valid.validated()) != nil)
        let path = TargetDiscoveryRequest(search_terms: ["Sources/Outbox/Queue.swift"],
            expected_symbol_kind: "method", expected_behavior: "removes delivered items",
            why_needed: "no confident initial target")
        #expect((try? path.validated()) == nil)
    }

    private func select(_ objective: String, order: [String]? = nil) -> ContextSelector.Selection {
        let paths = order ?? files.keys.sorted()
        return ContextSelector.select(objective: objective, paths: paths,
            evidence: paths.map { .init(path: $0, source: files[$0]!) })
    }
}
