import Foundation
import HarnessCore

/// What Computer Use did on this Mac, one JSON line per step (stage 2, 2026-10-18): the goal, the action, its result, and
/// for a risky step whether the user allowed it. ~/Library/Application Support/Harness/computer-use/YYYY-MM-DD.jsonl, kept
/// 90 days. It never holds what was typed into a password field (the agent does not type there).
struct ComputerUseJournal: Sendable {
    let folder: URL

    static var standard: ComputerUseJournal {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ComputerUseJournal(folder: support.appendingPathComponent("Harness/computer-use"))
    }

    func record(goal: String, step: ComputerUseStep? = nil, approval: (action: String, reason: String, allowed: Bool)? = nil,
                outcome: String? = nil, now: Date = Date()) {
        var entry: [String: Any] = ["time": ISO8601DateFormatter().string(from: now), "goal": goal]
        if let step { entry["action"] = step.action; entry["result"] = step.result }
        if let approval { entry["approval"] = ["action": approval.action, "reason": approval.reason, "allowed": approval.allowed] }
        if let outcome { entry["outcome"] = outcome }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        let day = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        let file = folder.appendingPathComponent("\(day).jsonl")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }
}
