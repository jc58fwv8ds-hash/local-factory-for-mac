import Foundation

public enum ModelCapabilityParser {
    public static func ollamaVisualCapabilities(_ output: String) -> Set<VisualModelCapability> {
        let capabilities = capabilityLines(in: output)
        var result: Set<VisualModelCapability> = []
        if capabilities.contains("completion") || !capabilities.contains("embedding") {
            result.insert(.textConversation)
        }
        if capabilities.contains("vision") {
            result.insert(.imageUnderstanding)
        }
        return result
    }

    public static func ollamaSupportsConversation(_ output: String) -> Bool {
        ollamaVisualCapabilities(output).contains(.textConversation)
    }

    private static func capabilityLines(in output: String) -> Set<String> {
        let lines = output
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let heading = lines.firstIndex(of: "capabilities") else {
            return ["completion"]
        }
        return Set(lines[lines.index(after: heading)...].prefix { !$0.isEmpty })
    }
}
