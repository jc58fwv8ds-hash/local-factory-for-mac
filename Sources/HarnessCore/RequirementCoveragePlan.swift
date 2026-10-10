import Foundation

/// Model-produced, machine-checkable plan: the objective split into requirements,
/// each bound to editable targets or an explicit no-change reason.
public struct RequirementCoveragePlan: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public let requirement: String
        /// IDs of the deterministic objective clauses this requirement was derived from.
        public let source_clause_ids: [String]
        public let relevant_symbols: [String]
        public let editable_targets: [String]
        public let read_only_evidence: [String]
        public let rationale: String
        public let coverage: String // complete | incomplete | uncertain
        public let no_change_reason: String?
        public init(requirement: String, source_clause_ids: [String] = [], relevant_symbols: [String], editable_targets: [String],
                    read_only_evidence: [String], rationale: String, coverage: String, no_change_reason: String? = nil) {
            self.requirement = requirement; self.source_clause_ids = source_clause_ids; self.relevant_symbols = relevant_symbols
            self.editable_targets = editable_targets; self.read_only_evidence = read_only_evidence
            self.rationale = rationale; self.coverage = coverage; self.no_change_reason = no_change_reason
        }
    }
    public let requirements: [Item]
    public init(requirements: [Item]) { self.requirements = requirements }
}

struct CoveragePlanSchema: Encodable {
    struct Text: Encodable { let type = "string"; let maxLength = 240 }
    struct Texts: Encodable { let type = "array"; let items = Text(); let maxItems = 4 }
    struct ClauseIDs: Encodable { let type = "array"; let items = Text(); let minItems = 1; let maxItems = 8 }
    struct Coverage: Encodable { let type = "string"; let `enum` = ["complete", "incomplete", "uncertain"] }
    struct Item: Encodable {
        struct Properties: Encodable {
            let requirement = Text()
            let source_clause_ids = ClauseIDs()
            let relevant_symbols = Texts()
            let editable_targets = Texts()
            let read_only_evidence = Texts()
            let rationale = Text()
            let coverage = Coverage()
            let no_change_reason = Text()
        }
        let type = "object"
        let properties = Properties()
        let required = ["requirement", "source_clause_ids", "relevant_symbols", "editable_targets", "read_only_evidence", "rationale", "coverage", "no_change_reason"]
        let additionalProperties = false
    }
    struct Items: Encodable { let type = "array"; let items = Item(); let minItems = 1; let maxItems = 6 }
    struct Properties: Encodable { let requirements = Items() }
    let type = "object"
    let properties = Properties()
    let required = ["requirements"]
    let additionalProperties = false
}
