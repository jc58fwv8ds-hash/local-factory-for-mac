import Foundation

/// Where the project already has a value of the type a call wants (2026-11-18: a new history screen took
/// `store: TranscriptStore`; the screen that opened it passed `controller.transcriptStore`, an array of another type, and
/// six repairs changed the screens back and forth without finding `TranscriptStore.shared`).
public enum ProjectValueLookup {
    public static func hint(for message: String, projectRoot: URL) -> String? {
        guard let range = message.range(of: #"to expected argument type '([A-Z][A-Za-z0-9_]*)'"#, options: .regularExpression) else { return nil }
        let type = String(message[range].split(separator: "'")[1])
        var found: [String] = []
        for url in ProjectCallLookup.swiftFiles(in: projectRoot) where !url.path.contains("Tests/") {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let name = url.lastPathComponent
            for line in text.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.range(of: #"static (let|var) \w+\s*(:\s*"# + type + #")?\s*=\s*"# + type + #"\("#, options: .regularExpression) != nil
                    || t.range(of: #"\b(let|var) \w+\s*:\s*"# + type + #"\b"#, options: .regularExpression) != nil
                    || t.range(of: #"\b(let|var) \w+\s*=\s*"# + type + #"\("#, options: .regularExpression) != nil {
                    found.append("\(name): \(t.prefix(120))")
                }
            }
            if found.count >= 6 { break }
        }
        guard !found.isEmpty else {
            return "\(type) の値は、このプロジェクトのどこにも持たれていません。\(type)() で作るか、受け取る側を今ある値の型に合わせてください。"
        }
        return "\(type) の値は、このプロジェクトでは次の所にあります(渡すならこのどれかを使い、ほかの型の値を渡さないこと):\n"
            + found.map { "- " + $0 }.joined(separator: "\n")
    }
}
