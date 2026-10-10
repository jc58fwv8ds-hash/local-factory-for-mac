import Foundation
import HarnessCore

enum ReplanGUIFixture {
    static func prepare() throws {
        let manager = FileManager.default
        let container = manager.temporaryDirectory.appendingPathComponent(
            "Harness-GUI-Replan-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectRoot = container.appendingPathComponent(
            "Project",
            isDirectory: true
        )
        let sourceDirectory = projectRoot.appendingPathComponent(
            "Sources/ReplanFixture",
            isDirectory: true
        )
        try manager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data(packageManifest.utf8).write(
            to: projectRoot.appendingPathComponent("Package.swift"),
            options: .atomic
        )
        try Data(brokenSource.utf8).write(
            to: sourceDirectory.appendingPathComponent("ReplanFixture.swift"),
            options: .atomic
        )

        let modelEntry = try require(ModelCatalogEntry.recommended.first)
        let first = WorkItem(
            title: "失敗原因を小さく直す",
            detail: "コンパイルエラーを解消して同じ検証へ合格する",
            status: .active
        )
        let second = WorkItem(
            title: "再起動後も結果を保つ",
            detail: "検証と計画の状態が失われない",
            status: .pending
        )
        let project = HarnessProject(
            name: "使い捨て再計画GUI検査",
            summary: "保存済みプロジェクトへ触れない隔離評価",
            targets: [.macOS],
            stage: .test,
            progress: 0.6,
            currentActivity: "意図したコンパイル失敗を確認します",
            workItems: [first, second],
            activity: [],
            selectedModel: ModelSelection(
                identifier: modelEntry.ollamaIdentifier,
                displayName: modelEntry.displayName,
                runtime: .ollama
            ),
            creationLoop: CreationLoopState(phase: .awaitingUserDecision),
            runCoordinator: RunCoordinatorState(
                phase: .awaitingValidation,
                currentWorkItemID: first.id,
                attemptedCycleCount: 1
            )
        )
        let record = ProjectRecord(
            project: project,
            origin: .imported,
            sourceLocation: projectRoot.path
        )
        let workspaceURL = container.appendingPathComponent("Workspace/workspace.json")
        let sourcePrefix = projectRoot.standardizedFileURL.path + "/"
        guard !workspaceURL.standardizedFileURL.path.hasPrefix(sourcePrefix) else {
            throw CheckFailure(description: "GUI fixture workspace entered the source root")
        }
        try WorkspaceRepository(fileURL: workspaceURL).saveLibrary(
            ProjectLibrary(records: [record], selectedProjectID: project.id)
        )

        let output = FixtureOutput(
            rootPath: projectRoot.path,
            workspacePath: workspaceURL.path
        )
        let data = try JSONEncoder().encode(output)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CheckFailure(description: "GUI fixture result was not UTF-8")
        }
        print(text)
    }

    private static let packageManifest = """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "ReplanFixture",
        products: [.library(name: "ReplanFixture", targets: ["ReplanFixture"])],
        targets: [.target(name: "ReplanFixture")]
    )
    """

    private static let brokenSource = """
    public func greeting() -> String {
        missingGreeting
    }
    """
}

private struct FixtureOutput: Encodable {
    let rootPath: String
    let workspacePath: String
}
