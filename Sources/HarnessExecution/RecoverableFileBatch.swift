import Foundation
import HarnessCore

/// Aggregate write-ahead state around the existing file adapter; never runs generated code.
public actor RecoverableFileBatch {
    public enum Failure: Error { case invalidState, stalePrecondition, conflict, protectedChanged }
    public enum Direction: String, Codable, Sendable { case resume, rollback }
    public struct FileState: Codable, Sendable {
        public let path: String
        public let original: String
        public let intended: String
        public let originalHash: String
        public let intendedHash: String
        public var expectedPrecondition: String
        public var resultingHash: String?
        public var status: String
        public let rollbackHash: String
    }
    public struct State: Codable, Sendable {
        public let schemaVersion: Int
        public let rootPath: String
        public let protectedHashes: [String: String]
        public var direction: Direction
        public var phase: String
        public var files: [FileState]
    }
    private let directory: URL
    private let adapter = ProjectFileEditor()
    public init(directory: URL) { self.directory = directory }

    public func prepare(root: URL, proposals: [FileChangeProposal], allowed: Set<String>,
                        protected: Set<String>) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lease = try LocalExecutionLease(file: directory.appendingPathComponent("lease"))
        let workspaceLease = try rootLease(root)
        defer { withExtendedLifetime((lease, workspaceLease)) {} }
        guard !FileManager.default.fileExists(atPath: stateURL.path), !proposals.isEmpty,
              proposals.count <= 20, Set(proposals.map(\.relativePath)).count == proposals.count,
              proposals.allSatisfy({ $0.operation == .update && allowed.contains($0.relativePath) && !protected.contains($0.relativePath) })
        else { throw Failure.invalidState }
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        var files: [FileState] = []
        for p in proposals {
            let current = try await adapter.load(rootPath: canonical.path, relativePath: p.relativePath)
            guard current.content == p.originalContent else { throw Failure.stalePrecondition }
            let originalHash = hash(p.originalContent), intendedHash = hash(p.proposedContent)
            guard originalHash != intendedHash else { throw Failure.invalidState }
            files.append(.init(path: p.relativePath, original: p.originalContent, intended: p.proposedContent,
                originalHash: originalHash, intendedHash: intendedHash, expectedPrecondition: originalHash,
                resultingHash: originalHash, status: "unapplied", rollbackHash: originalHash))
        }
        var protectedHashes: [String: String] = [:]
        for path in protected {
            protectedHashes[path] = hash(try await adapter.load(rootPath: canonical.path, relativePath: path).content)
        }
        try save(.init(schemaVersion: 1, rootPath: canonical.path, protectedHashes: protectedHashes,
            direction: .resume, phase: "prepared", files: files))
    }

    /// Contents, not the last status flag, decide what survived a crash.
    public func inspect(root: URL) async throws -> State {
        let lease = try LocalExecutionLease(file: directory.appendingPathComponent("lease"))
        let workspaceLease = try rootLease(root)
        defer { withExtendedLifetime((lease, workspaceLease)) {} }
        var state = try load(root: root)
        try await reconcile(&state)
        try save(state)
        return state
    }

    public func run(root: URL, direction: Direction? = nil,
                    afterWrite: @Sendable (Int) throws -> Void = { _ in }) async throws -> State {
        let lease = try LocalExecutionLease(file: directory.appendingPathComponent("lease"))
        let workspaceLease = try rootLease(root)
        defer { withExtendedLifetime((lease, workspaceLease)) {} }
        var state = try load(root: root)
        let direction = direction ?? state.direction
        try await reconcile(&state)
        state.direction = direction
        // A foreign/partial-byte edit is not ours to overwrite, even during rollback.
        guard !state.files.contains(where: { $0.status == "conflict" }) else {
            state.phase = "blockedConflict"; try save(state); throw Failure.conflict
        }
        state.phase = direction == .resume ? "applying" : "rollingBack"
        try save(state)
        let indices = direction == .resume ? Array(state.files.indices) : Array(state.files.indices.reversed())
        for i in indices {
            try Task.checkCancellation()
            try await checkProtected(state)
            let f = state.files[i]
            let desired = direction == .resume ? f.intended : f.original
            let expected = direction == .resume ? f.original : f.intended
            let current = try await adapter.load(rootPath: state.rootPath, relativePath: f.path)
            if current.content == desired { continue }
            guard current.content == expected else {
                state.phase = "blockedConflict"; state.files[i].status = "conflict"
                state.files[i].resultingHash = hash(current.content)
                try save(state); throw Failure.stalePrecondition
            }
            state.files[i].expectedPrecondition = hash(expected)
            state.files[i].status = "writePending"
            try save(state) // Durable intent BEFORE the actual file write.
            let proposal = try await adapter.makeProposal(document: current, proposedContent: desired)
            try await adapter.apply(rootPath: state.rootPath, proposal: proposal)
            try afterWrite(i) // Failure-injection seam; state deliberately may lag actual bytes.
            let after = try await adapter.load(rootPath: state.rootPath, relativePath: f.path)
            state.files[i].resultingHash = hash(after.content)
            guard after.content == desired else { throw Failure.conflict }
            state.files[i].status = direction == .resume ? "applied" : "unapplied"
            try save(state)
        }
        try await reconcile(&state)
        let expectedStatus = direction == .resume ? "applied" : "unapplied"
        guard state.files.allSatisfy({ $0.status == expectedStatus }) else {
            state.phase = "blockedConflict"; try save(state); throw Failure.conflict
        }
        state.phase = direction == .resume ? "applied" : "rolledBack"
        try save(state)
        return state
    }
    private var stateURL: URL { directory.appendingPathComponent("transaction.json") }
    private func rootLease(_ root: URL) throws -> LocalExecutionLease {
        let locks = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessCandidate/BatchWriteLocks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try LocalExecutionLease(file: locks.appendingPathComponent(hash(root.standardizedFileURL.resolvingSymlinksInPath().path)))
    }
    private func hash(_ text: String) -> String { ValidationSourceIdentity.hash(Data(text.utf8)) }
    private func load(root: URL) throws -> State {
        let info = try stateURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 4_000_000 else { throw Failure.invalidState }
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
        guard state.schemaVersion == 1, state.rootPath == root.standardizedFileURL.resolvingSymlinksInPath().path,
              !state.files.isEmpty, state.files.count <= 20, Set(state.files.map(\.path)).count == state.files.count,
              state.files.allSatisfy({ hash($0.original) == $0.originalHash && hash($0.intended) == $0.intendedHash &&
                  $0.rollbackHash == $0.originalHash && state.protectedHashes[$0.path] == nil })
        else { throw Failure.invalidState }
        return state
    }
    private func checkProtected(_ state: State) async throws {
        for (path, digest) in state.protectedHashes {
            guard hash(try await adapter.load(rootPath: state.rootPath, relativePath: path).content) == digest else {
                throw Failure.protectedChanged
            }
        }
    }
    private func reconcile(_ state: inout State) async throws {
        try await checkProtected(state)
        for i in state.files.indices {
            guard let document = try? await adapter.load(rootPath: state.rootPath, relativePath: state.files[i].path) else {
                state.files[i].resultingHash = nil; state.files[i].status = "conflict"; continue
            }
            let content = document.content
            let digest = hash(content)
            state.files[i].resultingHash = digest
            state.files[i].status = digest == state.files[i].originalHash ? "unapplied" :
                (digest == state.files[i].intendedHash ? "applied" : "conflict")
        }
    }
    private func save(_ state: State) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        let file = try FileHandle(forWritingTo: stateURL)
        defer { try? file.close() }
        try file.synchronize()
    }
}
