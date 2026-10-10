import Foundation
import Testing
@testable import HarnessCore
@testable import HarnessExecution

struct ReverseReferenceExpansionTests {
    let declaration = "Sources/Domain/Seed.swift"
    func seeds(_ sources: [String: String]) -> [RepositorySymbolIndex.Match] {
        RepositorySymbolIndex(sources: sources).retrieve(clauses: ObjectiveClauses.segment("Add label to Parcel"))
    }
    @Test func boundedOneHopDeterministicReadOnlyEvidence() {
        var sources = [declaration: "struct Parcel {}", "Sources/Domain/Next.swift": "struct Next { let item: First }",
            "Sources/Domain/Noise.swift": "// Parcel\nstruct Noise { let text = \"Parcel\" }"]
        for name in ["First", "Second", "Third", "Fourth"] {
            sources["Sources/Domain/\(name).swift"] = "struct \(name) { let item: Parcel }"
        }
        let result = ReverseReferenceExpansion.discover(seeds: seeds(sources), sources: sources,
            alreadySelected: [declaration], protected: [])
        #expect(result.count == 3)
        #expect(!result.contains { $0.candidateFile.hasSuffix("Next.swift") || $0.candidateFile.hasSuffix("Noise.swift") })
        #expect(result.allSatisfy { $0.reason.contains("READ-ONLY") && $0.seedSymbol == "Parcel" })
        #expect(result == ReverseReferenceExpansion.discover(seeds: seeds(sources), sources: sources,
            alreadySelected: [declaration], protected: []))
    }
    @Test func protectedTestsCannotSeedOrBecomeEvidence() {
        let hidden = "Tests/DomainTests/Hidden.swift"
        let sources = [declaration: "struct Parcel {}", hidden: "struct Consumer { let item: Parcel }"]
        #expect(ReverseReferenceExpansion.discover(seeds: seeds(sources), sources: sources,
            alreadySelected: [declaration], protected: [hidden]).isEmpty)
    }
    @Test func noAutomaticEditablePermission() {
        let owner = "Sources/Domain/Handler.swift"
        let sources = [declaration: "struct Parcel {}", owner: "struct Handler { func take(_ p: Parcel) {} }"]
        let evidence = ReverseReferenceExpansion.discover(seeds: seeds(sources), sources: sources,
            alreadySelected: [declaration], protected: [])
        #expect(evidence.count == 1)
        let plan = RequirementCoveragePlan(requirements: [.init(requirement: "Add acceptParcel to Handler", source_clause_ids: ["C1"],
            relevant_symbols: ["Handler", "acceptParcel"], editable_targets: [], read_only_evidence: [owner], rationale: "owner", coverage: "uncertain", no_change_reason: "")])
        let gaps = TargetCoverage.assess(plan, objective: "Parcel handling", editable: [declaration], readOnly: [owner], sources: sources)
        #expect(!TargetCoverage.blockingGaps(gaps).isEmpty)
        let verdict = TargetCoverage.verify(.init(requirement_id: "R1", file: owner, symbol: "Handler", relation: "uses Parcel", why_edit: "add method"),
            gaps: gaps, objective: "Parcel handling", editable: [declaration], sources: sources, tests: [:], protected: [])
        #expect(verdict.accepted)
    }
    @Test func contractLimitsArePublishedAndConsistent() throws {
        let data = try JSONEncoder().encode(InferenceJSONSchema.targetDiscoveryRequest)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(json["properties"] as? [String: [String: Any]])
        #expect(properties["why_needed"]?["maxLength"] as? Int == 300)
        #expect(properties["expected_behavior"]?["maxLength"] as? Int == 300)
        #expect(properties["expected_symbol_kind"]?["maxLength"] as? Int == 80)
        #expect(properties["search_terms"]?["minItems"] as? Int == 1)
        func request(_ why: String) -> TargetDiscoveryRequest { .init(search_terms: ["Parcel"], expected_symbol_kind: "type", expected_behavior: "find", why_needed: why) }
        _ = try request(String(repeating: "x", count: 300)).validated()
        #expect(throws: (any Error).self) { try request(String(repeating: "x", count: 301)).validated() }
        #expect(TargetDiscoveryRequest.promptContract.contains("300"))
    }
    @Test func finalizesEarlyFailureAndSuccess() async {
        enum Stop: Error { case early }
        var count = 0
        do { let _: Int = try await TaskFinalization.run(operation: { throw Stop.early }, finalize: { count += 1 }) } catch {}
        let value = await TaskFinalization.run(operation: { 7 }, finalize: { count += 1 })
        #expect(count == 2 && value == 7)
    }
}
