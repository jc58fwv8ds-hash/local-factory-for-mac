import Foundation

public struct StructuredEditBatch: Codable, Sendable {
    public struct Edit: Codable, Sendable {
        public let operation: String
        public let file: String
        public let expected_old_text: String
        public let new_text: String
    }
    /// Structured Missing-Context request: the model names what it needs and why;
    /// the Harness decides deterministically whether it is admitted.
    public struct ContextRequest: Codable, Sendable, Equatable {
        public let file: String?
        public let symbol: String?
        public let why_needed: String
        public let relation: String
        public let operation: String // "read" or "edit"
        public init(file: String?, symbol: String?, why_needed: String, relation: String, operation: String) {
            self.file = file; self.symbol = symbol; self.why_needed = why_needed
            self.relation = relation; self.operation = operation
        }
    }
    public let edits: [Edit]
    public let context_request: ContextRequest?

    public init(edits: [Edit], context_request: ContextRequest? = nil) {
        self.edits = edits; self.context_request = context_request
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        edits = try values.decodeIfPresent([Edit].self, forKey: .edits) ?? []
        context_request = try values.decodeIfPresent(ContextRequest.self, forKey: .context_request)
    }

    /// A Windows-style path ("Sources\\A\\B.swift") is resolved only when replacing "\\" by "/" names exactly one of
    /// the files the batch was offered; anything else is left unchanged and still rejected by `proposedContents`.
    public func resolvingSeparators(knownFiles: Set<String>) -> StructuredEditBatch {
        StructuredEditBatch(edits: edits.map { edit in
            let resolved = edit.file.replacingOccurrences(of: "\\", with: "/")
            guard edit.file.contains("\\"), knownFiles.contains(resolved) else { return edit }
            return Edit(operation: edit.operation, file: resolved, expected_old_text: edit.expected_old_text, new_text: edit.new_text)
        }, context_request: context_request)
    }

    /// Validates the whole batch before any write; limits are supplied by the scope owner.
    public func proposedContents(originals: [String: String], protected: Set<String>,
        appendOnly: Set<String>, maxEdits: Int, maxLines: Int) throws -> [String: String] {
        guard !edits.isEmpty, edits.count <= maxEdits else { throw StructuredEditError.scopeViolation }
        var contents = originals
        var changed: Set<String> = []
        var lineBudget = 0
        for edit in edits {
            guard let source = contents[edit.file], !protected.contains(edit.file),
                  !edit.file.hasPrefix("/"), !edit.file.contains("\\"),
                  !edit.file.split(separator: "/").contains(".."),
                  !edit.new_text.contains("\r"), !(edit.new_text.isEmpty && edit.operation != "replace_exact") else {
                throw StructuredEditError.scopeViolation
            }
            switch edit.operation {
            case "replace_exact":
                guard !appendOnly.contains(edit.file), !edit.expected_old_text.isEmpty,
                      edit.expected_old_text != edit.new_text else { throw StructuredEditError.invalidInstruction }
                let parts = source.components(separatedBy: edit.expected_old_text)
                guard parts.count == 2 else { throw StructuredEditError.ambiguousAnchor }
                contents[edit.file] = parts[0] + edit.new_text + parts[1]
                lineBudget += edit.expected_old_text.components(separatedBy: "\n").count
            case "append_block":
                guard appendOnly.contains(edit.file), edit.expected_old_text.isEmpty,
                      source.hasSuffix("\n") else { throw StructuredEditError.scopeViolation }
                contents[edit.file] = source + edit.new_text + "\n"
            default: throw StructuredEditError.invalidInstruction
            }
            lineBudget += edit.new_text.components(separatedBy: "\n").count
            guard lineBudget <= maxLines else { throw StructuredEditError.scopeViolation }
            changed.insert(edit.file)
        }
        guard changed.allSatisfy({ contents[$0] != originals[$0] }) else { throw StructuredEditError.invalidInstruction }
        return contents.filter { changed.contains($0.key) }
    }
}
