import Foundation
import HarnessExecution

/// Persistence and repository discovery for the developer Shadow screen.
struct DogfoodShadowWorkspace {
    struct SavedPlan: Sendable {
        let result: DogfoodShadowResult
        let path: String
        let explorationMilliseconds: Int
    }

    func createPlan(rootPath: String, objective: String,
                    onProgress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SavedPlan {
        let started = ContinuousClock.now
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            throw ShadowWorkspaceError.notRepository
        }
        let paths = try repositoryPaths(at: root, onProgress: onProgress)
        let evidence = repositoryEvidence(at: root, paths: paths)
        let input = DogfoodShadowInput(taskID: UUID().uuidString,
            objective: objective, repositoryPaths: paths, localModelCompatible: false,
            externalReadiness: ExternalDispatchReadiness(ready: false,
                reasons: ["D0 UI does not authorize external dispatch"], inferenceCalls: 0),
            solAvailable: false, astraAvailable: false)
        let plan = try DogfoodShadowPlanner.plan(input, evidence: evidence)
        let elapsed = started.duration(to: .now)
        let milliseconds = Int((Double(elapsed.components.seconds) * 1_000)
            + (Double(elapsed.components.attoseconds) / 1_000_000_000_000_000))
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(HarnessAppEnvironment.supportFolderName() + "/Dogfood/Results", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = directory.appendingPathComponent(plan.taskID + ".json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        return SavedPlan(result: plan, path: output.path,
            explorationMilliseconds: milliseconds)
    }

    private func repositoryEvidence(at root: URL, paths: [String]) -> [ContextFileEvidence] {
        var evidence: [ContextFileEvidence] = []
        var bytesRead = 0
        for path in paths where evidence.count < 600 && bytesRead < 8_000_000 {
            guard ["swift", "go", "py", "js", "ts", "tsx", "rs"]
                .contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { continue }
            let file = root.appendingPathComponent(path)
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 256_000, bytesRead + size <= 8_000_000,
                  let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            evidence.append(ContextFileEvidence(path: path, source: source))
            bytesRead += size
        }
        return evidence
    }

    private func repositoryPaths(at root: URL,
                                 onProgress: @Sendable (String) -> Void) throws -> [String] {
        let excluded = Set([".git", ".build", "Build", "Builds", "DerivedData",
                            "node_modules", "xcuserdata", "dogfood-ui-v2", "dogfood-ui-v3",
                            "dogfood-ui-v4"])
        let deadline = Date().addingTimeInterval(10)
        var pending = [root]
        var paths: [String] = []
        while let directory = pending.popLast() {
            if Date() > deadline { throw ShadowWorkspaceError.timedOut }
            onProgress(String(directory.path.dropFirst(root.path.count)))
            let entries = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
            for entry in entries {
                if Task.isCancelled { throw CancellationError() }
                let relative = String(entry.path.dropFirst(root.path.count + 1))
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true || excluded.contains(entry.lastPathComponent) { continue }
                if !Self.includesPath(relative) { continue }
                if values.isDirectory == true { pending.append(entry) }
                else { paths.append(relative) }
                if paths.count + pending.count > 20_000 { throw ShadowWorkspaceError.repositoryTooLarge }
            }
        }
        return paths.sorted()
    }

    static func includesPath(_ relative: String) -> Bool {
        !relative.hasPrefix("work/") || relative == "work/PersonalMemory"
            || relative.hasPrefix("work/PersonalMemory/")
    }
}

private enum ShadowWorkspaceError: LocalizedError {
    case notRepository, cannotReadRepository, repositoryTooLarge, timedOut
    var errorDescription: String? {
        switch self {
        case .notRepository: "Gitの作業フォルダを選んでください。"
        case .cannotReadRepository: "作業フォルダを読めません。"
        case .repositoryTooLarge: "ファイルが多すぎます。範囲を絞ってください。"
        case .timedOut: "ファイルの確認が長すぎます。範囲を絞ってください。"
        }
    }
}
