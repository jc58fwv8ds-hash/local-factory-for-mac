import Foundation

public struct WorkspaceRepository {
    private let fileURL: URL
    private let backupURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if let fileURL {
            self.fileURL = fileURL
        } else {
            let supportDirectory = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.fileURL = supportDirectory
                .appendingPathComponent("Harness", isDirectory: true)
                .appendingPathComponent("workspace.json")
        }
        self.backupURL = Self.makeBackupURL(for: self.fileURL)
    }

    public func loadLibrary() throws -> ProjectLibrary? {
        try loadWorkspace().library
    }

    public func loadWorkspace() throws -> WorkspaceLoadResult {
        if fileManager.fileExists(atPath: fileURL.path),
           let library = try? decodeLibrary(at: fileURL) {
            return WorkspaceLoadResult(library: library, source: .primary)
        }

        if fileManager.fileExists(atPath: backupURL.path),
           let library = try? decodeLibrary(at: backupURL) {
            return WorkspaceLoadResult(library: library, source: .backup)
        }

        let hasUnreadableFile = fileManager.fileExists(atPath: fileURL.path)
            || fileManager.fileExists(atPath: backupURL.path)
        guard !hasUnreadableFile else {
            throw WorkspaceRepositoryError.noRecoverableWorkspace
        }
        return WorkspaceLoadResult(library: nil, source: .none)
    }

    public func saveLibrary(_ library: ProjectLibrary) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encodedLibrary = try encoder.encode(library)

        if fileManager.fileExists(atPath: fileURL.path) {
            if let currentData = try? Data(contentsOf: fileURL),
               (try? decodeLibrary(from: currentData)) != nil {
                try currentData.write(to: backupURL, options: .atomic)
            } else {
                try requireValidBackup()
            }
        } else if fileManager.fileExists(atPath: backupURL.path) {
            try requireValidBackup()
        } else {
            try encodedLibrary.write(to: backupURL, options: .atomic)
        }

        try encodedLibrary.write(to: fileURL, options: .atomic)
    }

    private func requireValidBackup() throws {
        guard fileManager.fileExists(atPath: backupURL.path),
              (try? decodeLibrary(at: backupURL)) != nil else {
            throw WorkspaceRepositoryError.refusingToOverwriteCorruptWorkspace
        }
    }

    private func decodeLibrary(at url: URL) throws -> ProjectLibrary {
        try decodeLibrary(from: Data(contentsOf: url))
    }

    private func decodeLibrary(from data: Data) throws -> ProjectLibrary {
        let decoder = JSONDecoder()
        if let library = try? decoder.decode(ProjectLibrary.self, from: data) {
            return library
        }
        if let legacyProject = try? decoder.decode(HarnessProject.self, from: data) {
            return ProjectLibrary(records: [ProjectRecord(project: legacyProject)])
        }
        return try decoder.decode(ProjectLibrary.self, from: data)
    }

    private static func makeBackupURL(for fileURL: URL) -> URL {
        let directory = fileURL.deletingLastPathComponent()
        let fileExtension = fileURL.pathExtension
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let backupName = fileExtension.isEmpty
            ? "\(baseName).backup"
            : "\(baseName).backup.\(fileExtension)"
        return directory.appendingPathComponent(backupName)
    }
}
