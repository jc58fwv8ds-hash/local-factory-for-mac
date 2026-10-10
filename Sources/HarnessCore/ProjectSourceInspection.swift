import Foundation

public enum SourceHealth: String, Codable, Sendable {
    case healthy
    case limited
    case missing
    case unreadable
}

public enum SourceTechnology: String, Codable, CaseIterable, Identifiable, Sendable {
    case swift
    case xcode
    case javascript
    case web
    case python
    case rust
    case go

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .xcode: "Xcode"
        case .javascript: "JavaScript / TypeScript"
        case .web: "Web"
        case .python: "Python"
        case .rust: "Rust"
        case .go: "Go"
        }
    }
}

public struct SourceInspection: Codable, Equatable, Sendable {
    public let health: SourceHealth
    public let scannedAt: Date
    public let fileCount: Int
    public let directoryCount: Int
    public let totalBytes: Int64
    public let technologies: [SourceTechnology]
    public let hasGitRepository: Bool
    public let manifestNames: [String]
    public let revision: String?

    public init(
        health: SourceHealth,
        scannedAt: Date = .now,
        fileCount: Int = 0,
        directoryCount: Int = 0,
        totalBytes: Int64 = 0,
        technologies: [SourceTechnology] = [],
        hasGitRepository: Bool = false,
        manifestNames: [String] = [],
        revision: String? = nil
    ) {
        self.health = health
        self.scannedAt = scannedAt
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.totalBytes = totalBytes
        self.technologies = technologies
        self.hasGitRepository = hasGitRepository
        self.manifestNames = manifestNames
        self.revision = revision
    }

    public var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

public actor ProjectSourceScanner {
    private let fileManager: FileManager
    private let maxEntries: Int

    public init(maxEntries: Int = 2_500, fileManager: FileManager = .default) {
        self.maxEntries = max(1, maxEntries)
        self.fileManager = fileManager
    }

    public func inspect(path: String) -> SourceInspection {
        scan(path: path).inspection
    }

    func scan(path: String) -> ProjectSourceScan {
        let rootURL = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return ProjectSourceScan(inspection: SourceInspection(health: .missing))
        }
        guard isDirectory.boolValue else {
            return ProjectSourceScan(inspection: SourceInspection(health: .unreadable))
        }

        var encounteredReadError = false
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                encounteredReadError = true
                return true
            }
        ) else {
            return ProjectSourceScan(inspection: SourceInspection(health: .unreadable))
        }

        var fileCount = 0
        var directoryCount = 0
        var totalBytes: Int64 = 0
        var visitedEntries = 0
        var reachedLimit = false
        var technologies = Set<SourceTechnology>()
        var manifests = Set<String>()
        var snapshotEntries: [SourceSnapshotEntry] = []

        for case let url as URL in enumerator {
            visitedEntries += 1
            if visitedEntries > maxEntries {
                reachedLimit = true
                break
            }

            guard let values = try? url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey
                ]
            ) else {
                encounteredReadError = true
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }

            let name = url.lastPathComponent
            detectMarkers(
                name: name.lowercased(),
                pathExtension: url.pathExtension.lowercased(),
                technologies: &technologies,
                manifests: &manifests
            )

            let isEntryDirectory = values.isDirectory == true
            let isProjectContainer = ["xcodeproj", "xcworkspace"]
                .contains(url.pathExtension.lowercased())
            if isProjectContainer {
                enumerator.skipDescendants()
            }
            if values.isRegularFile == true || isProjectContainer {
                let relativePath = url.pathComponents
                    .suffix(max(1, enumerator.level))
                    .joined(separator: "/")
                snapshotEntries.append(
                    SourceSnapshotEntry(
                        relativePath: relativePath,
                        isDirectory: isEntryDirectory,
                        size: Int64(values.fileSize ?? 0),
                        modificationMilliseconds: values.contentModificationDate.map {
                            Int64(($0.timeIntervalSince1970 * 1_000).rounded())
                        } ?? 0
                    )
                )
                if isProjectContainer, snapshotEntries.count < maxEntries {
                    snapshotEntries.append(contentsOf: projectContainerEntries(
                        at: url,
                        relativePath: relativePath,
                        limit: maxEntries - snapshotEntries.count
                    ))
                }
            }

            if isEntryDirectory {
                directoryCount += 1
            } else if values.isRegularFile == true {
                fileCount += 1
                totalBytes += Int64(values.fileSize ?? 0)
            }
        }

        let hasGitRepository = fileManager.fileExists(
            atPath: rootURL.appendingPathComponent(".git", isDirectory: true).path
        )
        let health: SourceHealth
        if reachedLimit {
            health = .limited
        } else if encounteredReadError && fileCount == 0 && directoryCount == 0 {
            health = .unreadable
        } else {
            health = .healthy
        }

        let snapshot = SourceSnapshot(entries: snapshotEntries)
        return ProjectSourceScan(
            inspection: SourceInspection(
                health: health,
                fileCount: fileCount,
                directoryCount: directoryCount,
                totalBytes: totalBytes,
                technologies: SourceTechnology.allCases.filter(technologies.contains),
                hasGitRepository: hasGitRepository,
                manifestNames: manifests.sorted(),
                revision: snapshot.revision
            ),
            snapshot: snapshot
        )
    }

    private func detectMarkers(
        name: String,
        pathExtension: String,
        technologies: inout Set<SourceTechnology>,
        manifests: inout Set<String>
    ) {
        switch pathExtension {
        case "swift": technologies.insert(.swift)
        case "xcodeproj", "xcworkspace": technologies.insert(.xcode)
        case "js", "jsx", "ts", "tsx": technologies.insert(.javascript)
        case "html", "css": technologies.insert(.web)
        case "py": technologies.insert(.python)
        case "rs": technologies.insert(.rust)
        case "go": technologies.insert(.go)
        default: break
        }

        let knownManifests: Set<String> = [
            "package.swift",
            "package.json",
            "pyproject.toml",
            "requirements.txt",
            "cargo.toml",
            "go.mod"
        ]
        if knownManifests.contains(name) {
            manifests.insert(name)
        }

        switch name {
        case "package.swift": technologies.insert(.swift)
        case "package.json": technologies.insert(.javascript)
        case "pyproject.toml", "requirements.txt": technologies.insert(.python)
        case "cargo.toml": technologies.insert(.rust)
        case "go.mod": technologies.insert(.go)
        default: break
        }
    }

    private func projectContainerEntries(
        at containerURL: URL,
        relativePath: String,
        limit: Int
    ) -> [SourceSnapshotEntry] {
        guard limit > 0 else { return [] }
        let metadataPath: String
        switch containerURL.pathExtension.lowercased() {
        case "xcodeproj": metadataPath = "project.pbxproj"
        case "xcworkspace": metadataPath = "contents.xcworkspacedata"
        default: return []
        }
        let metadataURL = containerURL.appendingPathComponent(metadataPath)
        guard let values = try? metadataURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true else { return [] }
        return [
            SourceSnapshotEntry(
                relativePath: "\(relativePath)/\(metadataPath)",
                isDirectory: false,
                size: Int64(values.fileSize ?? 0),
                modificationMilliseconds: values.contentModificationDate.map {
                    Int64(($0.timeIntervalSince1970 * 1_000).rounded())
                } ?? 0
            )
        ]
    }
}
