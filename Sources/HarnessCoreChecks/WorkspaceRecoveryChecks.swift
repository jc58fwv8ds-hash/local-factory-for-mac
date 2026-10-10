import Foundation
import HarnessCore

enum WorkspaceRecoveryChecks {
    static func run() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("workspace.json")
        let backupURL = directory.appendingPathComponent("workspace.backup.json")
        let repository = WorkspaceRepository(fileURL: fileURL)

        let emptyResult = try repository.loadWorkspace()
        try expect(
            emptyResult.library == nil && emptyResult.source == .none,
            "A new workspace should load as empty"
        )

        let firstLibrary = makeLibrary(named: "First generation")
        try repository.saveLibrary(firstLibrary)
        try expect(
            fileManager.fileExists(atPath: fileURL.path)
                && fileManager.fileExists(atPath: backupURL.path),
            "The first save must create a recoverable backup"
        )

        let secondLibrary = makeLibrary(named: "Second generation")
        try repository.saveLibrary(secondLibrary)
        try expect(
            try WorkspaceRepository(fileURL: backupURL).loadLibrary() == firstLibrary,
            "A save must keep the previous valid generation as backup"
        )

        try Data("{broken primary".utf8).write(to: fileURL, options: .atomic)
        let recoveredResult = try repository.loadWorkspace()
        try expect(
            recoveredResult.library == firstLibrary
                && recoveredResult.source == .backup
                && recoveredResult.recoveredFromBackup,
            "A corrupt primary workspace must recover from the previous generation"
        )

        let recoveredLibrary = makeLibrary(named: "Recovered generation")
        try repository.saveLibrary(recoveredLibrary)
        try expect(
            try repository.loadLibrary() == recoveredLibrary
                && WorkspaceRepository(fileURL: backupURL).loadLibrary() == firstLibrary,
            "Saving after recovery must preserve the last good backup"
        )
        print("✓ Workspace saves keep and restore the previous valid generation")

        let corruptDirectory = directory.appendingPathComponent("Corrupt", isDirectory: true)
        try fileManager.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corruptFileURL = corruptDirectory.appendingPathComponent("workspace.json")
        let corruptBackupURL = corruptDirectory.appendingPathComponent("workspace.backup.json")
        let corruptPrimaryData = Data("bad primary".utf8)
        let corruptBackupData = Data("bad backup".utf8)
        try corruptPrimaryData.write(to: corruptFileURL)
        try corruptBackupData.write(to: corruptBackupURL)
        let corruptRepository = WorkspaceRepository(fileURL: corruptFileURL)

        try expectThrows("Unreadable workspace generations must report an error") {
            _ = try corruptRepository.loadWorkspace()
        }
        try expectThrows("Unrecoverable workspace files must not be overwritten") {
            try corruptRepository.saveLibrary(firstLibrary)
        }
        try expect(
            try Data(contentsOf: corruptFileURL) == corruptPrimaryData
                && Data(contentsOf: corruptBackupURL) == corruptBackupData,
            "Failed recovery must leave both workspace files untouched"
        )
        print("✓ Unrecoverable workspace files are reported and never overwritten")
    }

    private static func makeLibrary(named name: String) -> ProjectLibrary {
        var project = HarnessProject.starter
        project.name = name
        return ProjectLibrary(records: [ProjectRecord(project: project)])
    }
}
