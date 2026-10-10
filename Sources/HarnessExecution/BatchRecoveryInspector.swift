import Foundation
import HarnessCore

/// Read-only aggregate reconciliation. Never overwrites third-party edits or clears history.
public struct BatchRecoveryInspector: Sendable {
    public enum Status: String, Sendable {
        case unchanged, fullyApplied, partiallyApplied, conflict, unavailable
    }
    public init() {}
    public func inspect(root: URL, checkpoint: URL) async -> Status {
        do {
            let values = try checkpoint.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 1_000_000 else { return .unavailable }
            let data = try Data(contentsOf: checkpoint)
            guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["schemaVersion"] as? Int == 1,
                  record["rootPath"] as? String == root.standardizedFileURL.resolvingSymlinksInPath().path,
                  record["phase"] as? String == "admitted",
                  let originals = record["originals"] as? [String: String],
                  let response = record["response"] as? String,
                  let protected = record["protected"] as? [String],
                  let appendOnly = record["appendOnly"] as? [String],
                  let maxEdits = record["maxEdits"] as? Int,
                  let maxLines = record["maxLines"] as? Int else { return .unavailable }
            let batch = try JSONDecoder().decode(StructuredEditBatch.self, from: Data(StructuredResponseText.jsonObject(in: response).utf8))
                .resolvingSeparators(knownFiles: Set(originals.keys))
            let proposed = try batch.proposedContents(originals: originals, protected: Set(protected),
                appendOnly: Set(appendOnly), maxEdits: maxEdits, maxLines: maxLines)
            var applied = 0
            for (path, original) in originals {
                let current = try await ProjectFileEditor().load(rootPath: root.path, relativePath: path)
                if current.content == original { continue }
                guard let expected = proposed[path], current.content == expected else { return .conflict }
                applied += 1
            }
            guard try Data(contentsOf: checkpoint) == data else { return .unavailable }
            if applied == 0 { return .unchanged }
            return applied == proposed.count ? .fullyApplied : .partiallyApplied
        } catch { return .unavailable }
    }
}
