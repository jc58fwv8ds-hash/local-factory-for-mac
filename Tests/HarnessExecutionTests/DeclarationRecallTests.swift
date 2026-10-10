import Foundation
import HarnessCore
import Testing
@testable import HarnessExecution

/// Synthetic, task-independent checks: declaration-seeded reverse references, retained
/// candidates, declaration-first bounded snippets, behaviour ownership, and Target Replan
/// verification without editable targets.
struct DeclarationRecallTests {
    let sources: [String: String] = [
        "Sources/Orchard/Harvest.swift": "public enum HarvestGrade { case prime, standard, cull }\npublic struct HarvestLot { let grade: HarvestGrade; let weight: Int }",
        "Sources/Orchard/LotSorter.swift": "enum LotSorter { static func ordered(_ lots: [HarvestLot]) -> [HarvestLot] { lots } }",
        "Sources/Orchard/LotLabel.swift": "enum LotLabel { static func text(for lot: HarvestLot) -> String { \"\\(lot.weight)\" } }",
        "Sources/Orchard/Weather.swift": "struct Weather { let rain: Bool }",
        "Sources/Orchard/Irrigation.swift": "enum Irrigation { static func needed(_ w: Weather) -> Bool { !w.rain } }"
    ]
    let harvest = "Sources/Orchard/Harvest.swift", sorter = "Sources/Orchard/LotSorter.swift"
    let label = "Sources/Orchard/LotLabel.swift", weather = "Sources/Orchard/Weather.swift", irrigation = "Sources/Orchard/Irrigation.swift"

    func expand(selected: [String], targets: Set<String>, candidates: [RepositorySymbolIndex.Match] = [],
                objective: String = "prime の区分を先に並べて") -> [ReverseReferenceExpansion.Evidence] {
        DeclarationSeedExpansion.expand(selected: selected, targets: targets, objective: objective,
            initialCandidates: candidates, sources: sources, protected: [])
    }

    @Test func referencesOfTargetTypeDeclarationsBecomeReadOnlyEvidence() {
        // The objective only matched an enum case; the seed is the target file's declared types.
        let found = expand(selected: [harvest], targets: [harvest])
        #expect(found.map(\.candidateFile) == [label, sorter])
        #expect(found.allSatisfy { $0.relationType == "declaration_reference" && $0.reason.hasSuffix("READ-ONLY") })
        #expect(!found.map(\.candidateFile).contains(weather) && !found.map(\.candidateFile).contains(irrigation))
    }

    @Test func literalsAndGenericWordsNeverSeed() {
        #expect(!DeclarationSeedExpansion.isInformative("true"))
        #expect(!DeclarationSeedExpansion.isInformative("42"))
        #expect(!DeclarationSeedExpansion.isInformative("value"))
        #expect(DeclarationSeedExpansion.isInformative("HarvestLot"))
        let index = RepositorySymbolIndex(sources: sources)
        let seeds = DeclarationSeedExpansion.seeds(files: [weather], targets: [], objective: "雨の日", index: index)
        #expect(seeds.isEmpty) // an evidence file's types seed only when related to the objective
    }

    @Test func strongInitialCandidateIsRetainedWithRelation() {
        let candidate = RepositorySymbolIndex.Match(file: sorter, symbol: "ordered", clauseID: "C1", clauseText: "x",
            evidenceType: "referenced_symbol", score: 78, reason: "r")
        let weak = RepositorySymbolIndex.Match(file: irrigation, symbol: "needed", clauseID: "C1", clauseText: "x",
            evidenceType: "referenced_symbol", score: 78, reason: "r")
        // Evidence-only selection (not a target): its types do not seed, so only retention can add files.
        let found = DeclarationSeedExpansion.expand(selected: [harvest], targets: [], objective: "並べて",
            initialCandidates: [candidate, weak], sources: sources, protected: [])
        #expect(found.map(\.candidateFile) == [sorter])
        #expect(found.first?.relationType == "retained_candidate")
    }

    @Test func expansionIsDeterministicAndBounded() {
        let a = expand(selected: [harvest], targets: [harvest])
        let b = expand(selected: [harvest], targets: [harvest])
        #expect(a == b)
        #expect(a.count <= DeclarationSeedExpansion.maximumFiles)
        #expect(expand(selected: [harvest, sorter, label], targets: [harvest]).isEmpty) // never re-adds selected files
    }

    @Test func snippetPrefersDeclarationOverLiteral() {
        let filler = (0..<120).map { "    let filler\($0) = true // padding line" }.joined(separator: "\n")
        let source = "struct Top {\n" + filler + "\n}\npublic struct HarvestLot {\n    let weight: Int\n}\n" + filler.replacingOccurrences(of: "filler", with: "tail")
        let snippet = EvidenceSnippet.select(source: source, relevant: ["HarvestLot"], matched: "true", maximumCharacters: 1_500)
        #expect(snippet.contains("public struct HarvestLot"))
        #expect(snippet.count <= 1_700)
        #expect(snippet.contains("bounded evidence"))
    }

    @Test func snippetUsesContextTypeDeclarationsAndStaysBounded() {
        let filler = (0..<200).map { "    // note \($0)" }.joined(separator: "\n")
        let source = "import Foundation\n" + filler + "\npublic struct Receipt { let id: Int }\n" + filler
        let snippet = EvidenceSnippet.select(source: source, relevant: [], contextReferences: ["Receipt"], maximumCharacters: 1_200)
        #expect(snippet.contains("public struct Receipt"))
        #expect(snippet.count <= 1_400)
        let small = "struct Tiny {}"
        #expect(EvidenceSnippet.select(source: small, relevant: ["Tiny"]) == small) // small files unchanged
    }

    func item(_ requirement: String, symbols: [String]) -> RequirementCoveragePlan.Item {
        .init(requirement: requirement, source_clause_ids: ["C1"], relevant_symbols: symbols, editable_targets: [],
              read_only_evidence: [], rationale: "r", coverage: "complete", no_change_reason: "")
    }

    @Test func sharedDeclarationAloneIsNotOwner() {
        // Harvest.swift only declares the shared type; the ordering behaviour lives in LotSorter.
        let entries = TargetCoverage.assess(.init(requirements: [item("Order lots so prime comes first",
            symbols: ["HarvestLot", "LotSorter", "ordered"])]), objective: "prime を先に", editable: [harvest],
            readOnly: [sorter], sources: sources)
        #expect(entries[0].coverageState == .TARGET_COVERAGE_GAP && entries[0].blocking)
        #expect(entries[0].readOnlyEvidence == [sorter])
    }

    @Test func behaviourRelationMakesOwner() {
        let implementing = TargetCoverage.assess(.init(requirements: [item("Order lots so prime comes first",
            symbols: ["HarvestLot", "ordered"])]), objective: "prime を先に", editable: [sorter],
            readOnly: [harvest], sources: sources)
        #expect(implementing[0].coverageState == .COVERED)
        // Sole site: no READ-ONLY alternative implements or consumes the behaviour.
        let sole = TargetCoverage.assess(.init(requirements: [item("Grades stay as they are", symbols: ["HarvestGrade"])]),
            objective: "区分", editable: [harvest], readOnly: [weather], sources: sources)
        #expect(sole[0].coverageState == .COVERED)
    }

    @Test func readOnlyUserMakesSharedDeclarationAGapAndOwnsAfterPromotion() {
        let requirement = item("Weigh lots before labelling", symbols: ["HarvestLot", "weight"])
        let before = TargetCoverage.assess(.init(requirements: [requirement]), objective: "重さ", editable: [harvest],
                                           readOnly: [label], sources: sources)
        #expect(before[0].coverageState == .TARGET_COVERAGE_GAP && before[0].blocking && before[0].readOnlyEvidence == [label])
        let after = TargetCoverage.assess(.init(requirements: [requirement]), objective: "重さ", editable: [harvest, label],
                                          readOnly: [], sources: sources)
        #expect(after[0].coverageState == .COVERED && after[0].reason.contains(label) && !after[0].reason.contains(harvest + ","))
    }

    @Test func nominationWithoutEditableTargetsUsesReadOnlyRelations() {
        let entries = TargetCoverage.assess(.init(requirements: [item("Order lots so prime comes first",
            symbols: ["HarvestLot", "LotSorter", "ordered"])]), objective: "並べ替えを変えて", editable: [],
            readOnly: [harvest, sorter, weather], sources: sources)
        let gaps = TargetCoverage.blockingGaps(entries)
        #expect(!gaps.isEmpty)
        func verify(_ file: String, _ symbol: String) -> TargetCoverage.Verdict {
            TargetCoverage.verify(.init(requirement_id: "R1", file: file, symbol: symbol, relation: "", why_edit: "x"),
                gaps: gaps, objective: "並べ替えを変えて", editable: [], sources: sources, tests: [:], protected: [])
        }
        let ok = verify(sorter, "ordered")
        #expect(ok.accepted && ok.evidence.contains { $0.hasPrefix("peer: references HarvestLot declared by READ-ONLY") })
        let unrelated = verify(weather, "Weather")
        #expect(!unrelated.accepted)
    }

    @Test func noRelationIsRejectedAndNothingBecomesEditable() {
        let lonely: [String: String] = ["Sources/A/Alpha.swift": "struct Alpha { func run() {} }",
                                        "Sources/A/Beta.swift": "struct Beta { func go() {} }"]
        let entries = TargetCoverage.assess(.init(requirements: [item("Change run", symbols: ["Alpha", "run"])]),
            objective: "動きを変えて", editable: [], readOnly: ["Sources/A/Alpha.swift", "Sources/A/Beta.swift"], sources: lonely)
        let verdict = TargetCoverage.verify(.init(requirement_id: "R1", file: "Sources/A/Alpha.swift", symbol: "run",
            relation: "", why_edit: "x"), gaps: TargetCoverage.blockingGaps(entries), objective: "動きを変えて",
            editable: [], sources: lonely, tests: [:], protected: [])
        #expect(!verdict.accepted && verdict.rejection == "insufficientEvidence")
        // Expansion output is READ-ONLY evidence only: it carries no promotion field at all.
        let found = expand(selected: [harvest], targets: [harvest])
        #expect(found.allSatisfy { $0.reason.contains("READ-ONLY") })
    }
}
