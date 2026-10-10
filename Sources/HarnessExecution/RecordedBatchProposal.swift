import Foundation
import HarnessCore

/// Durable one-attempt batch admission. A saved uncertain run is never freely retried.
public actor RecordedBatchProposal {
    public enum Failure: Error { case alreadyStarted, oversizedResponse }
    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func prepare(root: URL, files: [String], objective: String, model: String,
        protected: Set<String>, appendOnly: Set<String>, maxEdits: Int, maxLines: Int,
        editor: RecordedProjectFileEditor,
        generate: @Sendable ([String: String]) async throws -> String) async throws -> [FileChangeProposal] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lease = try LocalExecutionLease(file: directory.appendingPathComponent("lease"))
        defer { withExtendedLifetime(lease) {} }
        let state = directory.appendingPathComponent("checkpoint.json")
        guard !FileManager.default.fileExists(atPath: state.path) else { throw Failure.alreadyStarted }
        var documents: [String: EditableSourceDocument] = [:]
        for file in files { documents[file] = try await editor.load(rootPath: root.path, relativePath: file) }
        let originals = documents.mapValues(\.content)
        var record: [String: Any] = ["schemaVersion": 1,
            "rootPath": root.standardizedFileURL.resolvingSymlinksInPath().path,
            "phase": "generating", "model": model, "objective": objective,
            "originals": originals, "protected": protected.sorted(), "appendOnly": appendOnly.sorted(),
            "maxEdits": maxEdits, "maxLines": maxLines, "attempts": 1]
        try save(record, to: state)
        do {
            let response = try await generate(originals)
            guard response.utf8.count <= 32_000 else { throw Failure.oversizedResponse }
            record["response"] = response
            record["phase"] = "responseSaved"
            try save(record, to: state)
            let batch = try JSONDecoder().decode(StructuredEditBatch.self, from: Data(StructuredResponseText.jsonObject(in: response).utf8))
                .resolvingSeparators(knownFiles: Set(originals.keys))
            let contents = try batch.proposedContents(originals: originals, protected: protected,
                appendOnly: appendOnly, maxEdits: maxEdits, maxLines: maxLines)
            var proposals: [FileChangeProposal] = []
            for file in contents.keys.sorted() {
                guard let document = documents[file], let content = contents[file] else { continue }
                proposals.append(try await editor.makeProposal(document: document,
                                                               proposedContent: Self.addingFoundationImport(file, Self.retiringEmptySource(file, content))))
            }
            record["phase"] = "admitted"
            try save(record, to: state)
            return proposals
        } catch {
            record["phase"] = "rejectedOrUnavailable"
            record["error"] = String(describing: error)
            try save(record, to: state)
            throw error
        }
    }
    private func save(_ record: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static let retiredSourceContent = "// The contents of this file were removed by this change.\n"

    /// A batch that removes all code of a production source (e.g. a retired rule) keeps the file with one comment line:
    /// empty files stay refused by the editor, and the transaction can still roll the file back.
    static func retiringEmptySource(_ path: String, _ content: String) -> String {
        path.hasPrefix("Sources/") && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? retiredSourceContent : content
    }

    /// APIs that exist only with Foundation; a source using them without any import does not compile, and the model's
    /// repair rarely notices the missing import (recorded c2-15, c2-17, b5-12).
    static let foundationOnlyAPIs = [".components(separatedBy:", ".trimmingCharacters(in:", ".replacingOccurrences(of:",
        ".range(of:", ".data(using:", "String(format:", "CharacterSet", "NSRegularExpression", "DateFormatter",
        "NumberFormatter", "Date()", "Date(timeIntervalSince", "URL(string:", "Decimal(", "JSONEncoder", "JSONDecoder",
        ".capitalized", ".padding(toLength:", ".contains(where: CharacterSet", ".folding(options:"]

    /// A production source that uses Foundation-only APIs and imports nothing gets `import Foundation` at the top.
    static func addingFoundationImport(_ path: String, _ content: String) -> String {
        guard path.hasPrefix("Sources/"), content.range(of: #"(?m)^\s*(@\w+\s+)*import\s"#, options: .regularExpression) == nil,
              foundationOnlyAPIs.contains(where: content.contains) else { return content }
        return "import Foundation\n\n" + content
    }
}
