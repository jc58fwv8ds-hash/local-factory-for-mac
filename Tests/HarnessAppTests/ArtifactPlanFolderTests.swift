import Foundation
import HarnessCore
import Testing

/// 2026-11-26 baseline (mojisu, an empty project): every multi-file plan stopped with 「作成先フォルダが存在しません」 for
/// Sources/line-stats, Sources/LineCounter and Tests, although Tests existed and Sources/line-stats was made by hand.
struct ArtifactPlanFolderTests {
    private func plan(_ paths: [String], existing: [String]) throws -> ArtifactCreationPlan {
        let files = paths.map { #"{"path":"\#($0)","instruction":"作る"}"# }.joined(separator: ",")
        return try ArtifactPlanResponseParser.plan(from: #"{"files":["# + files + "]}", instruction: "x", existingPaths: existing)
    }

    @Test func anEmptyProjectsPlanMayPutFilesInNewFolders() throws {
        let made = try plan(["Package.swift", "Sources/line-stats/main.swift", "Tests/LineStatsTests/LineStatsTests.swift"], existing: [])
        #expect(made.targets.count == 3)
        #expect(try plan(["Sources/LineCounter/Counter.swift", "Tests/CounterTests.swift"], existing: ["Package.swift"]).targets.count == 2)
    }

    @Test func newFoldersStayBoundedAndVisible() {
        let available: Set<String> = [".", "sources"]
        #expect(ArtifactPlanDirectoryPolicy.allowsParent("Sources", availableDirectories: available))
        #expect(ArtifactPlanDirectoryPolicy.allowsParent("Sources/App/Views/Rows", availableDirectories: available))
        #expect(!ArtifactPlanDirectoryPolicy.allowsParent("A/B/C/D", availableDirectories: available))
        #expect(!ArtifactPlanDirectoryPolicy.allowsParent("Sources/.secret", availableDirectories: available))
        #expect(!ArtifactPlanDirectoryPolicy.allowsParent(".build/x", availableDirectories: available))
        #expect(!ArtifactPlanDirectoryPolicy.allowsParent("Sources/build", availableDirectories: available))
        #expect(throws: ArtifactPlanInferenceError.self) { try plan(["A/B/C/D/E.swift", "Sources/B.swift"], existing: []) }
    }

    @Test func theSaveSideMakesTheFoldersItWasAllowed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-folders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = ProjectFileEditor()
        // An existing empty folder and new folders under the root.
        try await editor.validateCreationPath(rootPath: root.path, relativePath: "Tests/MojisuTests.swift")
        try await editor.validateCreationPath(rootPath: root.path, relativePath: "Sources/line-stats/main.swift")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources").path))  // checking makes nothing
        await #expect(throws: ProjectFileEditError.self) {
            try await editor.validateCreationPath(rootPath: root.path, relativePath: "A/B/C/D/E.swift")
        }
        await #expect(throws: ProjectFileEditError.self) {
            try await editor.validateCreationPath(rootPath: root.path, relativePath: "Sources/.hidden/main.swift")
        }
        let proposal = try await editor.makeCreationProposal(rootPath: root.path, relativePath: "Sources/line-stats/main.swift",
                                                             proposedContent: "print(1)\n")
        try await editor.apply(rootPath: root.path, proposal: proposal)
        let written = root.appendingPathComponent("Sources/line-stats/main.swift")
        #expect(try String(contentsOf: written, encoding: .utf8) == "print(1)\n")
    }
}
