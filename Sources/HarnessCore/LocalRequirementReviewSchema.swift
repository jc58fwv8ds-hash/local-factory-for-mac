import Foundation

struct LocalRequirementReviewSchema: Encodable {
    struct Text: Encodable { let type = "string"; let maxLength: Int }
    struct Status: Encodable { let type = "string"; let `enum` = ["SATISFIED", "VIOLATED", "UNCERTAIN"] }
    struct Item: Encodable {
        struct Properties: Encodable {
            let id = Text(maxLength: 40)
            let verdict = Status()
            let evidence = Text(maxLength: 800)
            let file = Text(maxLength: 512)
            let symbol = Text(maxLength: 160)
        }
        let type = "object", properties = Properties()
        let required = ["id", "verdict", "evidence", "file", "symbol"]
        let additionalProperties = false
    }
    struct Items: Encodable { let type = "array"; let items = Item(); let minItems = 1; let maxItems = 32 }
    struct Properties: Encodable { let items = Items() }
    let type = "object", properties = Properties()
    let required = ["items"]
    let additionalProperties = false
}
