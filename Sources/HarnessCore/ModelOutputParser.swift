import Foundation

public enum ModelOutputParser {
    public static func parseOllamaList(_ output: String) -> [InstalledModel] {
        output
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line in
                let columns = line.split(whereSeparator: \.isWhitespace)
                guard columns.count >= 4 else { return nil }
                let identifier = String(columns[0])
                let size = "\(columns[2]) \(columns[3])"
                return InstalledModel(
                    identifier: identifier,
                    displayName: identifier,
                    sizeLabel: size,
                    runtime: .ollama
                )
            }
    }

    public static func parseLMStudioJSON(_ output: String) -> [InstalledModel] {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        return dictionaries(in: root).compactMap { dictionary in
            if let type = dictionary["type"] as? String, type != "llm" {
                return nil
            }
            let identifier = firstString(
                in: dictionary,
                keys: ["modelKey", "model_key", "key", "identifier"]
            )
            guard let identifier, !identifier.isEmpty else { return nil }

            let displayName = firstString(
                in: dictionary,
                keys: ["displayName", "display_name", "name"]
            ) ?? identifier
            let path = firstString(in: dictionary, keys: ["path", "modelPath", "model_path"])
            let sizeLabel = formattedSize(from: dictionary)
            var capabilities: Set<VisualModelCapability> = [.textConversation]
            if (dictionary["vision"] as? Bool) == true {
                capabilities.insert(.imageUnderstanding)
            }

            return InstalledModel(
                identifier: identifier,
                displayName: displayName,
                sizeLabel: sizeLabel,
                runtime: .lmStudio,
                localPath: path,
                capabilities: capabilities
            )
        }
        .uniqued(by: \.id)
    }

    private static func dictionaries(in value: Any) -> [[String: Any]] {
        if let dictionary = value as? [String: Any] {
            return [dictionary] + dictionary.values.flatMap(dictionaries)
        }
        if let array = value as? [Any] {
            return array.flatMap(dictionaries)
        }
        return []
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { dictionary[$0] as? String }.first
    }

    private static func formattedSize(from dictionary: [String: Any]) -> String {
        for key in ["sizeBytes", "size_bytes", "size"] {
            if let bytes = dictionary[key] as? NSNumber {
                return ByteCountFormatter.string(
                    fromByteCount: bytes.int64Value,
                    countStyle: .file
                )
            }
            if let label = dictionary[key] as? String {
                return label
            }
        }
        return "サイズ不明"
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
