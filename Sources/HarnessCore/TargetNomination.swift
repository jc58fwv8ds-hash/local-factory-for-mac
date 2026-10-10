import Foundation

/// Model answer to a Target Replan: which existing file (and symbol) must become editable
/// for a requirement that has no editable owner. A nomination is only a request; the
/// Harness promotes a file solely on deterministic code evidence.
public struct TargetNomination: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public let requirement_id: String
        public let file: String
        public let symbol: String
        public let relation: String
        public let why_edit: String
        public init(requirement_id: String, file: String, symbol: String, relation: String, why_edit: String) {
            self.requirement_id = requirement_id; self.file = file; self.symbol = symbol
            self.relation = relation; self.why_edit = why_edit
        }
    }
    public static let maximumItems = 4
    public let nominations: [Item]
    public init(nominations: [Item]) { self.nominations = nominations }
}

struct TargetNominationSchema: Encodable {
    struct Text: Encodable { let type = "string"; let maxLength = 240 }
    struct Item: Encodable {
        struct Properties: Encodable {
            let requirement_id = Text()
            let file = Text()
            let symbol = Text()
            let relation = Text()
            let why_edit = Text()
        }
        let type = "object"
        let properties = Properties()
        let required = ["requirement_id", "file", "symbol", "relation", "why_edit"]
        let additionalProperties = false
    }
    struct Items: Encodable { let type = "array"; let items = Item(); let maxItems = TargetNomination.maximumItems }
    struct Properties: Encodable { let nominations = Items() }
    let type = "object"
    let properties = Properties()
    let required = ["nominations"]
    let additionalProperties = false
}
