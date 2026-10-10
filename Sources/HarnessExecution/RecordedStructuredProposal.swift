import Foundation
import HarnessCore

/// One local model task with durable inputs/outcomes and a two-attempt limit.
/// Admission creates a proposal through the existing editor; it does not write source.
public actor RecordedStructuredProposal {
    public enum Failure: Error, Equatable { case changedTask, interrupted, retryLimit, responseTooLarge }
    private let directory: URL
    private let editor: RecordedProjectFileEditor

    public init(directory: URL, editor: RecordedProjectFileEditor) {
        self.directory = directory
        self.editor = editor
    }

    public func prepare(rootPath: String, target: String, objective: String, model: String,
        resumeInterrupted: Bool = false,
        generate: @Sendable (String) async throws -> String) async throws -> FileChangeProposal {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lease = try LocalExecutionLease(file: directory.appendingPathComponent("proposal.lock"))
        defer { withExtendedLifetime(lease) {} }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath().path
        let document = try await editor.load(rootPath: root, relativePath: target)
        let file = directory.appendingPathComponent("proposal-checkpoint.json")
        var state: StructuredProposalCheckpoint
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(StructuredProposalCheckpoint.self, from: Data(contentsOf: file))
            guard state.schemaVersion == 1, state.rootPath == root, state.target == target,
                  state.model == model, state.objective == objective,
                  state.originalContent == document.content, state.attempts.count <= 2,
                  ["ready", "generating", "interrupted", "accepted", "responseSaved", "rejected", "providerFailed"].contains(state.phase),
                  state.phase == "ready" || !state.attempts.isEmpty else { throw Failure.changedTask }
            if state.phase == "generating" {
                guard resumeInterrupted else { throw Failure.interrupted }
                state.attempts[state.attempts.count - 1].outcome = "INTERRUPTED_UNKNOWN_RESULT"
                state.phase = "interrupted"
                try save(state, to: file)
            }
        } else {
            state = .init(schemaVersion: 1, rootPath: root, target: target, model: model,
                objective: objective, originalContent: document.content, attempts: [], phase: "ready")
            try save(state, to: file)
        }
        if ["accepted", "responseSaved"].contains(state.phase) {
            guard let response = state.attempts.last?.response else { throw Failure.changedTask }
            do {
                let result = try await proposal(response: response, target: target, document: document)
                state.attempts[state.attempts.count - 1].outcome = "SCOPE_AND_SCHEMA_PASS"
                state.phase = "accepted"
                try save(state, to: file)
                return result
            } catch {
                state.attempts[state.attempts.count - 1].outcome = "SCOPE_OR_SCHEMA_REJECTED"
                state.phase = "rejected"
                try save(state, to: file)
                throw error
            }
        }
        guard state.attempts.count < 2 else { throw Failure.retryLimit }
        state.attempts.append(.init(id: UUID(), startedAt: Date(), response: nil, outcome: "GENERATING"))
        state.phase = "generating"
        try save(state, to: file)
        let response: String
        do {
            response = try await generate(document.content)
            guard response.utf8.count <= 16_000 else { throw Failure.responseTooLarge }
        } catch {
            state.attempts[state.attempts.count - 1].outcome = "LOCAL_PROVIDER_UNAVAILABLE_OR_RESPONSE_LIMIT"
            state.phase = "providerFailed"
            try save(state, to: file)
            throw error
        }
        state.attempts[state.attempts.count - 1].response = response
        state.phase = "responseSaved"
        try save(state, to: file)
        do {
            let result = try await proposal(response: response, target: target, document: document)
            state.attempts[state.attempts.count - 1].outcome = "SCOPE_AND_SCHEMA_PASS"
            state.phase = "accepted"
            try save(state, to: file)
            return result
        } catch {
            state.attempts[state.attempts.count - 1].outcome = "SCOPE_OR_SCHEMA_REJECTED"
            state.phase = "rejected"
            try save(state, to: file)
            throw error
        }
    }

    private func proposal(response: String, target: String,
                          document: EditableSourceDocument) async throws -> FileChangeProposal {
        let instruction = try JSONDecoder().decode(StructuredEditInstruction.self, from: Data(response.utf8))
        let scope = StructuredEditScope(allowedFiles: [target], allowedOperations: [.replaceExact],
            protectedFiles: [], maxChangedLines: 1)
        let content = try StructuredEditPrimitive.proposedContent(document.content,
            instruction: instruction, scope: scope)
        let proposal = try await editor.makeProposal(document: document, proposedContent: content)
        guard proposal.summary.addedLineCount == 1, proposal.summary.removedLineCount == 1 else {
            throw StructuredEditError.scopeViolation
        }
        return proposal
    }

    private func save(_ state: StructuredProposalCheckpoint, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
