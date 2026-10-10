import CryptoKit
import Foundation
import HarnessCore

/// Fingerprints local inputs, including project settings and tests. Does not read dependencies/build caches.
public enum ValidationSourceIdentity {
    private static let excluded = Set([
        ".git", ".build", ".swiftpm", "DerivedData", "build", "node_modules", ".DS_Store"
    ])

    public static func digest(root: URL) async throws -> String {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
            let inventory = try await BoundedCommandRunner(timeout: .seconds(10), maximumOutputBytes: 1_048_576).run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", root.path, "ls-files", "--cached", "--others", "--exclude-standard", "-t", "-z"]
            )
            guard inventory.exitCode == 0, !inventory.outputWasTruncated else {
                throw RecordedValidationError.sourceUnavailable
            }
            let paths = try Set(inventory.output.split(separator: "\0").map { entry -> String in
                // Status prefixes preserve leading filename whitespace through the text runner.
                guard ["H ", "S ", "M ", "? "].contains(where: { entry.hasPrefix($0) }) else {
                    throw RecordedValidationError.sourceUnavailable
                }
                return String(entry.dropFirst(2))
            })
            guard paths.count <= 10_000 else { throw RecordedValidationError.sourceTooLarge }
            let files = try paths.map { path in
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                guard !path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else {
                    throw RecordedValidationError.sourceUnavailable
                }
                return root.appendingPathComponent(path)
            }
            return try digest(files: files, root: root)
        }
        return try filesystemDigest(root: root)
    }

    private static func filesystemDigest(root: URL) throws -> String {
        var traversalFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
            errorHandler: { _, _ in traversalFailed = true; return false }
        ) else { throw RecordedValidationError.sourceUnavailable }
        var files: [URL] = []
        var visited = 0
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            if excluded.contains(file.lastPathComponent) || file.lastPathComponent.hasPrefix(".build-") {
                enumerator.skipDescendants()
                continue
            }
            visited += 1
            guard visited <= 10_000 else { throw RecordedValidationError.sourceTooLarge }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw RecordedValidationError.sourceUnavailable }
            guard values.isRegularFile == true else { continue }
            files.append(file)
        }
        guard !traversalFailed else { throw RecordedValidationError.sourceUnavailable }
        return try digest(files: files, root: root)
    }

    private static func digest(files: [URL], root: URL) throws -> String {
        var entries: [(String, String)] = []
        var totalBytes = 0
        for file in files {
            try Task.checkCancellation()
            guard file.resolvingSymlinksInPath().standardizedFileURL == file.standardizedFileURL else {
                throw RecordedValidationError.sourceUnavailable
            }
            let relativePath = String(file.path.dropFirst(root.path.count + 1))
            let values: URLResourceValues
            do {
                values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            } catch CocoaError.fileReadNoSuchFile {
                entries.append((relativePath, "missing"))
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw RecordedValidationError.sourceUnavailable
            }
            guard let size = values.fileSize, size <= 16 * 1_048_576 else {
                throw RecordedValidationError.sourceTooLarge
            }
            totalBytes += size
            guard totalBytes <= 64 * 1_048_576 else { throw RecordedValidationError.sourceTooLarge }
            let data = try Data(contentsOf: file)
            guard data.count == size else { throw RecordedValidationError.sourceChanged }
            entries.append((relativePath, hash(data)))
        }
        guard !entries.isEmpty else { throw RecordedValidationError.sourceUnavailable }
        let ordered = entries.sorted { $0.0 < $1.0 }.map { [$0.0, $0.1] }
        return hash(try JSONEncoder().encode(ordered))
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum RecordedValidationError: LocalizedError, Sendable {
    case sourceUnavailable, sourceTooLarge, sourceChanged, invalidReceipt, alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "検証対象を安全に読み取れませんでした。フォルダとリンクを確認してください。"
        case .sourceTooLarge: "検証対象が記録の上限を超えています。アプリのソースフォルダを選んでください。"
        case .sourceChanged: "検証中にファイルが変わったため、結果を確定していません。変更が落ち着いてから再検証してください。"
        case .invalidReceipt: "検証の記録を確認できないため、合格として保存しませんでした。"
        case .alreadyRunning: "このプロジェクトはすでに検証中です。"
        }
    }
}
