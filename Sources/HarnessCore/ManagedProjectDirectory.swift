import Foundation

public protocol ManagedProjectDirectoryProviding: Sendable {
    func prepare() throws -> URL
}

public enum ManagedProjectDirectoryError: LocalizedError, Sendable {
    case unavailable

    public var errorDescription: String? {
        "Local Factoryのプロジェクト保管場所を準備できませんでした。"
    }
}

public struct ManagedProjectDirectory: ManagedProjectDirectoryProviding, Sendable {
    private let baseDirectory: URL?

    public init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory
    }

    public func prepare() throws -> URL {
        let fileManager = FileManager.default
        let supportDirectory = baseDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        guard let supportDirectory else {
            throw ManagedProjectDirectoryError.unavailable
        }
        let projectsDirectory = supportDirectory
            .appendingPathComponent("Harness", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
            .standardizedFileURL
        do {
            try fileManager.createDirectory(
                at: projectsDirectory,
                withIntermediateDirectories: true
            )
            return projectsDirectory
        } catch {
            throw ManagedProjectDirectoryError.unavailable
        }
    }
}
