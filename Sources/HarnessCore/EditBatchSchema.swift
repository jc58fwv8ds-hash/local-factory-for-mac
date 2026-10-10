import Foundation

struct EditBatchSchema: Encodable {
    struct Text: Encodable { let type = "string" }
    struct Operation: Encodable {
        let type = "string"
        let `enum` = ["replace_exact", "append_block"]
    }
    struct Item: Encodable {
        struct Properties: Encodable {
            let operation = Operation()
            let file = Text()
            let expected_old_text = Text()
            let new_text = Text()
        }
        let type = "object"
        let properties = Properties()
        let required = ["operation", "file", "expected_old_text", "new_text"]
        let additionalProperties = false
    }
    struct Items: Encodable {
        let type = "array"
        let items = Item()
        let minItems = 0
        let maxItems = 6
    }
    struct Request: Encodable {
        struct Properties: Encodable {
            let file = Text()
            let symbol = Text()
            let why_needed = Text()
            let relation = Text()
            let operation = Operation2()
        }
        struct Operation2: Encodable { let type = "string"; let `enum` = ["read", "edit"] }
        let type = "object"
        let properties = Properties()
        let required = ["why_needed", "relation", "operation"]
        let additionalProperties = false
    }
    struct Properties: Encodable { let edits = Items(); let context_request = Request() }
    let type = "object"
    let properties = Properties()
    let required = ["edits"]
    let additionalProperties = false
}
