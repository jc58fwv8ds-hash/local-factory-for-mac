import Foundation
import HarnessCore

enum ProductionValidationStage: Int {
    case greeting = 1
    case farewell = 2
    case welcome = 3
}

struct ProductionMultiItemFixture {
    let root: URL
    private let manager = FileManager.default
    private let repository: WorkspaceRepository

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Harness-Multi-Item-E2E-\(UUID().uuidString)",
            isDirectory: true
        )
        self.root = root
        self.repository = WorkspaceRepository(
            fileURL: root.appendingPathComponent("Workspace/workspace.json")
        )
        do {
            try manager.createDirectory(
                at: root.appendingPathComponent("Sources/Greeting"),
                withIntermediateDirectories: true
            )
            try manager.createDirectory(
                at: root.appendingPathComponent("Tests/GreetingTests"),
                withIntermediateDirectories: true
            )
            try write(Self.package, to: "Package.swift")
            try write(Self.source, to: "Sources/Greeting/Greeting.swift")
            try activateValidation(.greeting)
        } catch {
            try? manager.removeItem(at: root)
            throw error
        }
    }

    func project(model: ModelSelection) -> HarnessProject {
        HarnessProject(
            name: "使い捨て複数項目E2E",
            summary: "再起動を挟む合成評価",
            targets: [.macOS],
            stage: .build,
            progress: 0.35,
            currentActivity: "複数項目E2Eを準備しています",
            workItems: [
                WorkItem(
                    title: "挨拶を仕上げる",
                    detail: "正しい日本語の挨拶を返す",
                    status: .pending
                ),
                WorkItem(
                    title: "別れの言葉を仕上げる",
                    detail: "短い日本語の別れを返す",
                    status: .pending
                ),
                WorkItem(
                    title: "名前付き挨拶を仕上げる",
                    detail: "受け取った名前を安全に含める",
                    status: .pending
                )
            ],
            activity: [],
            selectedModel: model,
            creationLoop: CreationLoopState(phase: .awaitingUserDecision)
        )
    }

    func activateValidation(_ stage: ProductionValidationStage) throws {
        try write(Self.tests(for: stage), to: "Tests/GreetingTests/GreetingTests.swift")
    }

    func restarted(_ project: HarnessProject) throws -> HarnessProject {
        let record = ProjectRecord(project: project, sourceLocation: root.path)
        let library = ProjectLibrary(
            records: [record],
            selectedProjectID: project.id
        )
        try repository.saveLibrary(library)
        guard let restored = try repository.loadLibrary()?.selectedRecord?.project else {
            throw CheckFailure(description: "Disposable workspace did not reload")
        }
        return restored
    }

    func remove() {
        guard root.lastPathComponent.hasPrefix("Harness-Multi-Item-E2E-") else { return }
        try? manager.removeItem(at: root)
    }

    private func write(_ text: String, to relativePath: String) throws {
        try Data(text.utf8).write(
            to: root.appendingPathComponent(relativePath),
            options: .atomic
        )
    }

    private static func tests(for stage: ProductionValidationStage) -> String {
        var cases = """
        @Test func greetingIsJapaneseHello() {
            #expect(greeting() == "こんにちは")
        }
        """
        if stage.rawValue >= ProductionValidationStage.farewell.rawValue {
            cases += """


            @Test func farewellIsFriendly() {
                #expect(farewell() == "またね")
            }
            """
        }
        if stage.rawValue >= ProductionValidationStage.welcome.rawValue {
            cases += """


            @Test func welcomeIncludesTheName() {
                #expect(welcome("ゆた") == "こんにちは、ゆたさん")
            }
            """
        }
        return """
        import Testing
        @testable import Greeting

        \(cases)
        """
    }

    private static let package = """
    // swift-tools-version: 6.2
    import PackageDescription
    let package = Package(
        name: "Greeting",
        products: [.library(name: "Greeting", targets: ["Greeting"])],
        targets: [
            .target(name: "Greeting"),
            .testTarget(name: "GreetingTests", dependencies: ["Greeting"])
        ]
    )
    """

    private static let source = """
    public func greeting() -> String {
        "未実装"
    }

    public func farewell() -> String {
        "未実装"
    }

    public func welcome(_ name: String) -> String {
        "未実装"
    }
    """
}
