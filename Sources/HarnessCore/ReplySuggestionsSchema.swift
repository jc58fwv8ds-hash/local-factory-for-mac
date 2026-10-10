import Foundation

struct ReplySuggestionsSchema: Encodable {
    struct Text: Encodable {
        let type = "string"
        let minLength = 1
        let maxLength: Int
    }

    struct Entry: Encodable {
        struct Properties: Encodable {
            let title = Text(maxLength: ReplySuggestion.maximumTitleCharacters)
            let instruction = Text(maxLength: ReplySuggestion.maximumInstructionCharacters)
            let effect = Text(maxLength: ReplySuggestion.maximumEffectCharacters)
        }
        let type = "object"
        let properties = Properties()
        let required = ["title", "instruction", "effect"]
        let additionalProperties = false
    }

    struct Items: Encodable {
        let type = "array"
        let items = Entry()
        let minItems = 2
        let maxItems = ReplySuggestion.maximumCount
    }

    struct Properties: Encodable {
        let suggestions = Items()
    }
    let type = "object"
    let properties = Properties()
    let required = ["suggestions"]
    let additionalProperties = false
}
