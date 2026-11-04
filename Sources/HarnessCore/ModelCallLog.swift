import Foundation

/// Every model request and its answer, appended one JSON line each (2026-10-11, backlog #41, after DeepSeek Harness's
/// "model-visible means logged"). A run binds the file with `ModelCallLog.$destination.withValue(...)`; the calls made in
/// that task tree are written there, so any request can be reconstructed and re-asked later (an examiner alarm could not
/// be checked on 2026-10-10 because nothing was kept). Local files only.
public enum ModelCallLog {
    @TaskLocal public static var destination: URL?

    private static let lock = NSLock()

    public static func record(_ request: InferenceRequest, response: String?, error: Error?, seconds: Double,
                              to file: URL? = destination) {
        guard let file else { return }
        var entry: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "runtime": request.runtime.rawValue,
            "model": request.modelIdentifier,
            "maximumOutputTokens": request.maximumOutputTokens,
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "seconds": (seconds * 10).rounded() / 10,
        ]
        if let temperature = request.temperature { entry["temperature"] = temperature }
        if !request.images.isEmpty { entry["images"] = request.images.count }
        if let response { entry["response"] = response }
        if let error { entry["error"] = String(describing: error) }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    /// Removes the lines about a chat the user deleted completely (2026-11-05): a message or answer equal to one of `texts`, or
    /// containing one of 8 characters or more (requests wrap the user's words). Short words like 「はい」 count only when equal.
    public static func remove(mentioning texts: [String], in folder: URL) {
        let wanted = Set(texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return }
        let long = wanted.filter { $0.count >= 8 }
        let matches = { (text: String) in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return wanted.contains(trimmed) || long.contains { trimmed.contains($0) }
        }
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jsonl" {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            let kept = lines.filter { line in
                guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return true }
                let said = ((entry["messages"] as? [[String: Any]]) ?? []).compactMap { $0["content"] as? String }
                return !(said + [entry["response"] as? String].compactMap { $0 }).contains(where: matches)
            }
            guard kept.count != lines.count else { continue }
            try? (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Removes daily files older than `days` in a folder of `YYYY-MM-DD.jsonl` logs.
    public static func prune(_ folder: URL, keepingDays days: Int = 14, now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "jsonl" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) > Double(days) * 86_400 { try? FileManager.default.removeItem(at: file) }
        }
    }
}
