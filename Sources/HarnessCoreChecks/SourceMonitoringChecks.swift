import Foundation
import HarnessCore

enum SourceMonitoringChecks {
    static func run() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessSourceMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstFile = rootURL.appendingPathComponent("App.swift")
        let secondFile = rootURL.appendingPathComponent("Feature.swift")
        try Data("struct App {}".utf8).write(to: firstFile)

        let monitor = ProjectSourceMonitor(maxEntries: 100)
        let initial = await monitor.inspect(path: rootURL.path, previousInspection: nil)
        try expect(
            initial.change == nil && initial.inspection.revision?.isEmpty == false,
            "Initial source monitoring must establish a revision without reporting a change"
        )

        try Data("struct App { let version = 2 }".utf8).write(to: firstFile)
        try Data("struct Feature {}".utf8).write(to: secondFile)
        let changed = await monitor.inspect(
            path: rootURL.path,
            previousInspection: initial.inspection
        )
        try expect(
            changed.change?.hasDetailedChanges == true
                && changed.change?.addedCount == 1
                && changed.change?.modifiedCount == 1
                && changed.change?.removedCount == 0
                && Set(changed.change?.samplePaths ?? []) == Set(["App.swift", "Feature.swift"]),
            "In-session source monitoring must report added and modified paths"
        )

        try FileManager.default.removeItem(at: secondFile)
        let removed = await monitor.inspect(
            path: rootURL.path,
            previousInspection: changed.inspection
        )
        try expect(
            removed.change?.removedCount == 1
                && removed.change?.fileCountDelta == -1,
            "In-session source monitoring must report removed paths"
        )
        print("✓ Source monitoring detects added, modified, and removed files in memory")

        try Data("struct App { let version = 300 }".utf8).write(to: firstFile)
        let restartedMonitor = ProjectSourceMonitor(maxEntries: 100)
        let afterRestart = await restartedMonitor.inspect(
            path: rootURL.path,
            previousInspection: removed.inspection
        )
        try expect(
            afterRestart.change?.hasDetailedChanges == false
                && afterRestart.inspection.revision != removed.inspection.revision,
            "Persisted source revisions must detect changes without persisting file paths"
        )

        let encodedInspection = try JSONEncoder().encode(afterRestart.inspection)
        var legacyObject = try require(
            JSONSerialization.jsonObject(with: encodedInspection) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "revision")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decodedLegacy = try JSONDecoder().decode(SourceInspection.self, from: legacyData)
        try expect(
            decodedLegacy.revision == nil
                && !String(decoding: encodedInspection, as: UTF8.self).contains("App.swift"),
            "Source revisions must migrate safely and never persist source paths"
        )
        print("✓ Source revisions survive restart without storing source paths or breaking old data")

        let projectContainer = rootURL.appendingPathComponent("Demo.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectContainer, withIntermediateDirectories: true)
        let projectFile = projectContainer.appendingPathComponent("project.pbxproj")
        try Data("// project v1".utf8).write(to: projectFile)
        let xcodeBaseline = await monitor.inspect(
            path: rootURL.path,
            previousInspection: afterRestart.inspection,
            detectsChanges: false
        )
        try Data("// project version two".utf8).write(to: projectFile)
        let xcodeChange = await monitor.inspect(
            path: rootURL.path,
            previousInspection: xcodeBaseline.inspection
        )
        try expect(
            xcodeChange.change?.modifiedCount == 1
                && xcodeChange.change?.samplePaths == ["Demo.xcodeproj/project.pbxproj"],
            "Xcode project metadata changes must be monitored without traversing package contents"
        )
        print("✓ Source monitoring includes bounded Xcode project metadata")
    }
}
