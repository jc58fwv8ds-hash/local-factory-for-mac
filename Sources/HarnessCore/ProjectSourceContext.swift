import Foundation

public struct SourceContextFile: Equatable, Sendable {
    public let relativePath: String
    public let content: String
    public let wasTruncated: Bool

    public init(relativePath: String, content: String, wasTruncated: Bool) {
        self.relativePath = relativePath
        self.content = content
        self.wasTruncated = wasTruncated
    }
}

public struct SourceContextSnapshot: Equatable, Sendable {
    public let files: [SourceContextFile]
    public let totalCharacters: Int
    public let wasTruncated: Bool
    public let skippedCandidateCount: Int

    public init(
        files: [SourceContextFile],
        totalCharacters: Int,
        wasTruncated: Bool,
        skippedCandidateCount: Int
    ) {
        self.files = files
        self.totalCharacters = totalCharacters
        self.wasTruncated = wasTruncated
        self.skippedCandidateCount = skippedCandidateCount
    }
}

public enum SourceContextError: LocalizedError, Equatable, Sendable {
    case missing
    case notDirectory
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .missing: "接続したソースフォルダが見つかりません。"
        case .notDirectory: "接続したソースはフォルダではありません。"
        case .unreadable: "接続したソースフォルダを読み取れません。"
        }
    }
}

public protocol ProjectSourceContextProviding: Sendable {
    func collect(
        path: String,
        budget: SourceContextBudget
    ) async throws -> SourceContextSnapshot
}

public extension ProjectSourceContextProviding {
    func collect(path: String) async throws -> SourceContextSnapshot {
        try await collect(path: path, budget: .standard)
    }
}

public actor ProjectSourceContextCollector: ProjectSourceContextProviding {
    private struct Candidate {
        let url: URL
        let relativePath: String
        let byteCount: Int
        let priority: Int
        let depth: Int
    }

    private let fileManager: FileManager
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func collect(
        path: String,
        budget: SourceContextBudget
    ) throws -> SourceContextSnapshot {
        let rootURL = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            throw SourceContextError.missing
        }
        guard isDirectory.boolValue else { throw SourceContextError.notDirectory }

        var encounteredReadError = false
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                encounteredReadError = true
                return true
            }
        ) else {
            throw SourceContextError.unreadable
        }

        var candidates: [Candidate] = []
        var visitedEntries = 0
        var reachedEntryLimit = false

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visitedEntries += 1
            if visitedEntries > budget.maxEntries {
                reachedEntryLimit = true
                break
            }

            let name = url.lastPathComponent.lowercased()
            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            ) else {
                encounteredReadError = true
                continue
            }

            if values.isDirectory == true {
                if SourceFilePolicy.excludedDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  SourceFilePolicy.isAllowedFile(url),
                  !SourceFilePolicy.isSensitiveFileName(name) else { continue }

            let relativePath = SourceFilePolicy.relativePath(for: url, rootURL: rootURL)
            candidates.append(
                Candidate(
                    url: url,
                    relativePath: relativePath,
                    byteCount: values.fileSize ?? 0,
                    priority: SourceFilePolicy.priority(for: url),
                    depth: relativePath.split(separator: "/").count
                )
            )
        }

        candidates.sort {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }

        var files: [SourceContextFile] = []
        var totalCharacters = 0
        var truncatedAnyFile = false

        for candidate in candidates.prefix(budget.maxFiles) {
            try Task.checkCancellation()
            let remainingCharacters = budget.maxTotalCharacters - totalCharacters
            guard remainingCharacters > 0 else { break }

            guard let loaded = try? load(
                candidate,
                maxFileBytes: budget.maxFileBytes,
                remainingCharacters: remainingCharacters
            ) else {
                encounteredReadError = true
                continue
            }
            guard !loaded.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            files.append(
                SourceContextFile(
                    relativePath: candidate.relativePath,
                    content: loaded.content,
                    wasTruncated: loaded.wasTruncated
                )
            )
            totalCharacters += loaded.content.count
            truncatedAnyFile = truncatedAnyFile || loaded.wasTruncated
        }

        if files.isEmpty && encounteredReadError && candidates.isEmpty {
            throw SourceContextError.unreadable
        }

        let skippedCount = max(0, candidates.count - files.count)
        return SourceContextSnapshot(
            files: files,
            totalCharacters: totalCharacters,
            wasTruncated: reachedEntryLimit || truncatedAnyFile || skippedCount > 0,
            skippedCandidateCount: skippedCount
        )
    }

    private func load(
        _ candidate: Candidate,
        maxFileBytes: Int,
        remainingCharacters: Int
    ) throws -> (content: String, wasTruncated: Bool) {
        let data: Data
        let wasByteTruncated = candidate.byteCount > maxFileBytes

        if wasByteTruncated {
            let handle = try FileHandle(forReadingFrom: candidate.url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maxFileBytes) ?? Data()
        } else {
            data = try Data(contentsOf: candidate.url, options: .mappedIfSafe)
        }

        guard !data.contains(0), let decoded = String(data: data, encoding: .utf8) else {
            return ("", false)
        }

        let content = String(decoded.prefix(remainingCharacters))
        return (
            content,
            wasByteTruncated || content.count < decoded.count
        )
    }

}
