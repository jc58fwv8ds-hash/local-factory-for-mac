import Foundation

/// One file operation from the chat in a common shape (backlog #42, 2026-10-11, after DeepSeek Harness's
/// pre-execute / post-execute tool hooks). Excel, PDF and Word edits and bulk renames all go through `perform`, so the
/// same checks run before anything touches a file and the same journal entry is written afterwards, whatever the tool.
struct FileOperation: Sendable {
    enum Kind: String, Codable, Sendable { case excel, pdf, word, rename }
    /// write: a new 「〜_編集済み」 file, or new names for a rename. revert: the written file to the Trash, or the old names back.
    enum Action: String, Codable, Sendable { case write, revert }

    let kind: Kind
    let action: Action
    let instruction: String
    /// Files the operation reads and must leave as they are (for a rename: the current names).
    let reads: [URL]
    /// Files the operation creates or moves to the Trash (for a rename: the names after the step).
    let writes: [URL]
}

protocol FileOperationHook: Sendable {
    /// Throws to stop the operation before anything is written.
    func before(_ operation: FileOperation) throws
    /// Runs after the operation, whether it succeeded or not.
    func after(_ operation: FileOperation, error: Error?)
}

extension FileOperationHook {
    func before(_ operation: FileOperation) throws {}
    func after(_ operation: FileOperation, error: Error?) {}
}

enum FileOperationRunner {
    /// Every hook's `before`, then the body, then every hook's `after` (also when a `before` or the body throws).
    static func perform<T>(_ operation: FileOperation, hooks: [any FileOperationHook], _ body: () throws -> T) throws -> T {
        do {
            for hook in hooks { try hook.before(operation) }
            let result = try body()
            for hook in hooks { hook.after(operation, error: nil) }
            return result
        } catch {
            for hook in hooks { hook.after(operation, error: error) }
            throw error
        }
    }
}

/// The originals are never written: an edit may only create a file that does not exist yet and is not one it reads, and
/// "取り消す" may only move a file this app wrote (「〜_編集済み」) to the Trash. A rename may not land on an existing file.
struct OriginalProtectionHook: FileOperationHook {
    enum Refusal: LocalizedError, Equatable {
        case overwritesOriginal(String), exists(String), notWrittenByApp(String)
        var errorDescription: String? {
            switch self {
            case .overwritesOriginal(let name): "「\(name)」は元のファイルなので書き換えません"
            case .exists(let name): "「\(name)」はもうあるので上書きしません"
            case .notWrittenByApp(let name): "「\(name)」はこのアプリが書き出したファイルではないので、ゴミ箱へ移しません"
            }
        }
    }

    func before(_ operation: FileOperation) throws {
        let reads = Set(operation.reads.map(\.standardizedFileURL.path))
        for url in operation.writes {
            let name = url.lastPathComponent
            switch (operation.kind, operation.action) {
            case (.rename, _):
                // Two-phase renames may swap names inside the plan; only a name outside the plan is protected.
                if !reads.contains(url.standardizedFileURL.path), FileManager.default.fileExists(atPath: url.path) { throw Refusal.exists(name) }
            case (_, .write):
                if reads.contains(url.standardizedFileURL.path) { throw Refusal.overwritesOriginal(name) }
                if FileManager.default.fileExists(atPath: url.path) { throw Refusal.exists(name) }
            case (_, .revert):
                if reads.contains(url.standardizedFileURL.path) || !url.deletingPathExtension().lastPathComponent.contains("_編集済み") {
                    throw Refusal.notWrittenByApp(name)
                }
            }
        }
    }
}

/// What the app did to the user's files, one JSON line each, in `~/Library/Application Support/Harness/file-operations/
/// YYYY-MM-DD.jsonl` (kept 90 days). Local only; it records paths and the request, never file contents.
struct FileOperationJournal: FileOperationHook {
    let folder: URL

    static var standard: FileOperationJournal {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileOperationJournal(folder: support.appendingPathComponent("Harness/file-operations"))
    }

    func after(_ operation: FileOperation, error: Error?) {
        var entry: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "kind": operation.kind.rawValue,
            "action": operation.action.rawValue,
            "instruction": operation.instruction,
            "reads": operation.reads.map(\.path),
            "writes": operation.writes.map(\.path),
            "outcome": error == nil ? "done" : "stopped",
        ]
        if let error { entry["error"] = error.localizedDescription }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let file = folder.appendingPathComponent("\(day).jsonl")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }
}
