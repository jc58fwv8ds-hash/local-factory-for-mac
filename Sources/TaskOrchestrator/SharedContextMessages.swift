import Foundation
import HarnessCore

/// Prompt-cache friendly messages (plan 0005): the single-line `EDITABLE: {...}` and `READ-ONLY: {...}` file maps move to a
/// system message and the instructions stay in the user turn. In package scope these two lines are identical for every plan
/// and proposal call of a task, so the server (Backburner's proxy saves the system preamble on the SSD) restores them in
/// ~0.1 s instead of re-reading thousands of tokens (measured: 5,144-token preamble, 41.4 s cold vs 5.0 s restored).
/// A prompt without those lines is sent unchanged as one user message.
enum SharedContextMessages {
    static let markers = ["EDITABLE: ", "READ-ONLY: "]

    static func messages(for prompt: String) -> [InferenceMessage] {
        var context: [String] = [], instructions: [String] = []
        for line in prompt.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let marker = markers.first(where: trimmed.hasPrefix) else { instructions.append(line); continue }
            context.append(trimmed)
            // The reference stays where the file map was, so the instruction order the prompt was written for is kept.
            instructions.append(String(line.prefix { $0 == " " }) + marker + "(file map in the system message)")
        }
        guard !context.isEmpty else { return [.init(role: .user, content: prompt)] }
        return [.init(role: .system, content: "Files of the Swift package for this task (JSON maps of path to content).\n"
                    + context.joined(separator: "\n")),
                .init(role: .user, content: instructions.joined(separator: "\n"))]
    }
}
