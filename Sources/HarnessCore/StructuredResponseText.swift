import Foundation

/// Some local models wrap a structured answer in a ``` fence or put a sentence before it even when a JSON schema is
/// requested. Only the wrapper is removed: the first balanced top-level JSON object is returned unchanged, so every
/// content check still applies to exactly what the model wrote. Text that already starts with `{` is returned as is.
public enum StructuredResponseText {
    public static func jsonObject(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return text }
        var start = text.firstIndex(of: "{")
        while let open = start {
            var depth = 0, inString = false, escaped = false, index = open
            while index < text.endIndex {
                let ch = text[index]
                if inString {
                    if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                } else if ch == "\"" { inString = true }
                else if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let candidate = String(text[open...index])
                        if (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) != nil { return candidate }
                        break
                    }
                }
                index = text.index(after: index)
            }
            start = text[text.index(after: open)...].firstIndex(of: "{")
        }
        return text
    }
}
