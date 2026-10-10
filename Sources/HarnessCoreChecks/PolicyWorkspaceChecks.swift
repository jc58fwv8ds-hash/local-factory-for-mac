import Foundation
import HarnessCore

enum PolicyWorkspaceChecks {
    static func run() async throws {
        let policy = PermissionPolicy()
        try expect(
            policy.requirement(for: .deleteFiles) == .askEveryTime
                && policy.requirement(for: .changeSigning) == .askEveryTime
                && policy.requirement(for: .publish) == .askEveryTime
                && policy.requirement(for: .installModels) == .askEveryTime
                && policy.requirement(for: .removeModels) == .askEveryTime
                && policy.requirement(for: .writeFiles) == .askEveryTime,
            "High-impact actions must require approval"
        )
        print("✓ High-impact actions require approval")

        try expect(
            policy.requirement(for: .readFiles) == .automatic
                && policy.requirement(for: .runBuild) == .automatic
                && policy.requirement(for: .runTests) == .automatic,
            "Normal development actions should be automatic"
        )
        print("✓ Read, build, and test actions remain automatic")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("workspace.json")
        let repository = WorkspaceRepository(fileURL: fileURL)
        let project = HarnessProject.starter
        let library = ProjectLibrary(records: [ProjectRecord(project: project)])

        try repository.saveLibrary(library)
        try expect(try repository.loadLibrary() == library, "Workspace repository round-trip failed")
        print("✓ Workspace repository preserves the project library")

        try JSONEncoder().encode(project).write(to: fileURL, options: .atomic)
        let migratedLibrary = try repository.loadLibrary()
        try expect(
            migratedLibrary?.records.count == 1
                && migratedLibrary?.selectedRecord?.project == project,
            "Legacy workspace migration failed"
        )
        print("✓ Legacy single-project data migrates automatically")

        let createdRecord = try ProjectFactory().makeRecord(
            from: ProjectDraft(name: "  Focus App  ", targets: [])
        )
        try expect(
            createdRecord.project.name == "Focus App"
                && createdRecord.project.targets == [.macOS]
                && createdRecord.project.workItems.count == 2,
            "Project factory normalization failed"
        )
        print("✓ Project creation rules are isolated and normalized")

        let analyzerDirectory = directory.appendingPathComponent("AnalyzerFixture", isDirectory: true)
        try FileManager.default.createDirectory(at: analyzerDirectory, withIntermediateDirectories: true)
        try Data().write(to: analyzerDirectory.appendingPathComponent("Package.swift"))
        try Data().write(to: analyzerDirectory.appendingPathComponent("package.json"))
        let inferredTargets = ProjectSourceAnalyzer().inferredTargets(at: analyzerDirectory)
        try expect(
            Set(inferredTargets) == Set([TargetPlatform.macOS, .web]),
            "Project source target inference failed"
        )
        print("✓ Project source analysis is isolated from the UI store")

        let sourceInspection = await ProjectSourceScanner().inspect(path: analyzerDirectory.path)
        try expect(
            sourceInspection.health == .healthy
                && sourceInspection.fileCount == 2
                && sourceInspection.technologies.contains(.swift)
                && sourceInspection.technologies.contains(.javascript)
                && sourceInspection.manifestNames == ["package.json", "package.swift"],
            "Read-only source inspection failed"
        )
        let missingInspection = await ProjectSourceScanner().inspect(
            path: analyzerDirectory.appendingPathComponent("Missing").path
        )
        try expect(missingInspection.health == .missing, "Missing source detection failed")
        let limitedInspection = await ProjectSourceScanner(maxEntries: 1).inspect(
            path: analyzerDirectory.path
        )
        try expect(limitedInspection.health == .limited, "Source inspection limit failed")
        print("✓ Source inspection is read-only, bounded, and detects missing paths")

        let contextDirectory = directory.appendingPathComponent("ContextFixture", isDirectory: true)
        let sourcesDirectory = contextDirectory.appendingPathComponent("Sources", isDirectory: true)
        let dependenciesDirectory = contextDirectory.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dependenciesDirectory, withIntermediateDirectories: true)
        try Data("// package manifest".utf8).write(
            to: contextDirectory.appendingPathComponent("Package.swift")
        )
        try Data("struct App { let title = \"Harness\" }".utf8).write(
            to: sourcesDirectory.appendingPathComponent("App.swift")
        )
        try Data("do not include".utf8).write(
            to: dependenciesDirectory.appendingPathComponent("Dependency.js")
        )
        try Data("TOKEN=private".utf8).write(to: contextDirectory.appendingPathComponent(".env"))
        try Data("private".utf8).write(
            to: contextDirectory.appendingPathComponent("credentials.json")
        )

        let sourceContext = try await ProjectSourceContextCollector().collect(
            path: contextDirectory.path
        )
        let contextPaths = Set(sourceContext.files.map(\.relativePath))
        try expect(
            contextPaths == Set(["Package.swift", "Sources/App.swift"])
                && sourceContext.totalCharacters <= 48_000,
            "Source context must include useful files while excluding dependencies and sensitive files"
        )

        let truncationDirectory = directory.appendingPathComponent("TruncationFixture", isDirectory: true)
        try FileManager.default.createDirectory(at: truncationDirectory, withIntermediateDirectories: true)
        try Data(String(repeating: "a", count: 5_000).utf8).write(
            to: truncationDirectory.appendingPathComponent("Huge.swift")
        )
        let truncatedContext = try await ProjectSourceContextCollector().collect(
            path: truncationDirectory.path,
            budget: SourceContextBudget(
                maxEntries: 100,
                maxFiles: 1,
                maxFileBytes: 1_200,
                maxTotalCharacters: 2_200
            )
        )
        try expect(
            truncatedContext.files.count == 1
                && truncatedContext.files[0].content.count == 1_200
                && truncatedContext.files[0].wasTruncated
                && truncatedContext.wasTruncated,
            "Source context byte and character limits failed"
        )
        print("✓ AI source context excludes risky paths and enforces strict size limits")

        var connectedLibrary = ProjectLibrary(records: [createdRecord])
        let didConnectSource = connectedLibrary.connectSource(
            at: analyzerDirectory.path,
            to: createdRecord.id
        )
        connectedLibrary.updateSourceInspection(sourceInspection, for: createdRecord.id)
        let duplicateSourceProject = makeProject(name: "Duplicate Source")
        connectedLibrary.add(ProjectRecord(project: duplicateSourceProject))
        let didAcceptDuplicate = connectedLibrary.connectSource(
            at: analyzerDirectory.path,
            to: duplicateSourceProject.id
        )
        try expect(
            didConnectSource
                && !didAcceptDuplicate
                && connectedLibrary.sourceRecord(at: analyzerDirectory)?.id == createdRecord.id
                && connectedLibrary.records.first(where: { $0.id == createdRecord.id })?.sourceInspection == sourceInspection,
            "Source folder connection or inspection persistence failed"
        )
        print("✓ Existing projects can connect one unique source folder")

        let didDisconnect = connectedLibrary.disconnectSource(from: createdRecord.id)
        try expect(
            didDisconnect
                && connectedLibrary.records.first(where: { $0.id == createdRecord.id })?.sourceLocation == nil
                && FileManager.default.fileExists(atPath: analyzerDirectory.path),
            "Disconnecting a source must remove only the Harness reference"
        )
        print("✓ Source connections can be removed without deleting original files")

        let clampedProject = HarnessProject(
            name: "Check",
            summary: "",
            targets: [.macOS],
            stage: .concept,
            progress: 1.5,
            currentActivity: "",
            workItems: [],
            activity: []
        )
        try expect(clampedProject.progress == 1, "Progress must be clamped to 0...1")
        print("✓ Progress stays in its valid range")

        try checkProjectLibrary(in: directory)
    }

    private static func checkProjectLibrary(in directory: URL) throws {
        var projectLibrary = ProjectLibrary(records: [ProjectRecord(project: .starter)])
        let secondProject = makeProject(name: "Second", targets: [.web])
        projectLibrary.add(ProjectRecord(project: secondProject))
        projectLibrary.rename(secondProject.id, to: "Renamed")
        try expect(
            projectLibrary.selectedRecord?.project.name == "Renamed"
                && projectLibrary.activeRecords.count == 2,
            "Project creation, selection, or rename failed"
        )

        let webMatches = projectLibrary.records(
            matching: ProjectLibraryQuery(searchText: "web", lifecycle: .active, sort: .name)
        )
        try expect(
            webMatches.count == 1 && webMatches.first?.id == secondProject.id,
            "Project library search or filter failed"
        )

        let updated = projectLibrary.updateProject(
            secondProject.id,
            from: ProjectDraft(
                name: "Updated",
                summary: "Edited project",
                targets: [.iPhone],
                stage: .design
            )
        )
        try expect(
            updated
                && projectLibrary.selectedRecord?.project.name == "Updated"
                && projectLibrary.selectedRecord?.project.targets == [.iPhone]
                && projectLibrary.selectedRecord?.project.stage == .design,
            "Project detail editing failed"
        )
        print("✓ Project search, filtering, sorting, and detail editing work")

        projectLibrary.archive(secondProject.id)
        try expect(
            projectLibrary.archivedRecords.count == 1
                && projectLibrary.selectedProjectID != secondProject.id,
            "Project archive or selection normalization failed"
        )
        projectLibrary.restore(secondProject.id)
        projectLibrary.moveToTrash(secondProject.id)
        try expect(projectLibrary.trashedRecords.count == 1, "Project trash failed")
        projectLibrary.restore(secondProject.id)
        projectLibrary.removeFromLibrary(secondProject.id)
        try expect(
            projectLibrary.records.count == 1
                && projectLibrary.records.first?.project.name == "Personal Memory",
            "Project removal from the library failed"
        )
        print("✓ Project lifecycle preserves safe library behavior")

        let sourceDirectory = directory.appendingPathComponent("ImportedSource", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let importedProject = makeProject(name: "Imported")
        projectLibrary.add(
            ProjectRecord(
                project: importedProject,
                origin: .imported,
                sourceLocation: sourceDirectory.path
            )
        )
        try expect(
            projectLibrary.sourceRecord(at: sourceDirectory)?.id == importedProject.id,
            "Duplicate imported source lookup failed"
        )
        projectLibrary.moveToTrash(importedProject.id)
        projectLibrary.removeFromLibrary(importedProject.id)
        try expect(
            FileManager.default.fileExists(atPath: sourceDirectory.path),
            "Removing an imported project must not delete its source directory"
        )
        print("✓ Library removal never deletes imported source files")
    }

    private static func makeProject(
        name: String,
        targets: [TargetPlatform] = [.macOS]
    ) -> HarnessProject {
        HarnessProject(
            name: name,
            summary: "",
            targets: targets,
            stage: .concept,
            progress: 0,
            currentActivity: "",
            workItems: [],
            activity: []
        )
    }
}
