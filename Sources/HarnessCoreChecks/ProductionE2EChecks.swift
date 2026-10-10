import Foundation
import HarnessCore

enum ProductionE2EChecks {
    private static let targetPath = "Sources/Greeting/Greeting.swift"

    static func run() async throws {
        let entry = try require(ModelCatalogEntry.recommended.first)
        let identifier = try require(entry.identifier(for: .ollama))
        let fixture = try ProductionFixture()
        defer { fixture.remove() }

        let model = ModelSelection(
            identifier: identifier,
            displayName: entry.displayName,
            runtime: .ollama
        )
        var project = fixture.project(model: model)
        let engine = ProductionE2EEngine(model: model)
        let startedAt = Date()

        let selection = try ProductionE2EEngine.selected(
            RunCoordinatorWorkflow.beginNext(in: &project)
        )
        try expect(
            selection.id == project.workItems[0].id,
            "The E2E coordinator selected an unexpected item"
        )

        let firstGeneration = Date()
        try await engine.applyModelEdit(
            instruction: "greeting()が「おはよう」を返すようにしてね。ほかの公開APIは増やさないで。",
            project: &project,
            rootPath: fixture.root.path,
            targetPath: Self.targetPath
        )
        let firstValidation = try await engine.validate(
            project: &project,
            rootPath: fixture.root.path
        )
        try expect(
            !firstValidation.succeeded
                && project.runCoordinator.phase == .awaitingRepair,
            "The intentionally conflicting first change did not reach repair"
        )

        _ = try ProductionE2EEngine.selected(
            RunCoordinatorWorkflow.resumeCurrent(in: &project)
        )
        let repairGeneration = Date()
        try await engine.applyModelEdit(
            instruction: "検証で期待値が違うと分かりました。greeting()が正確に「こんにちは」を返すよう修正してね。ほかは変えないで。",
            project: &project,
            rootPath: fixture.root.path,
            targetPath: Self.targetPath
        )
        let repairedValidation = try await engine.validate(
            project: &project,
            rootPath: fixture.root.path
        )
        try expect(
            repairedValidation.succeeded
                && project.runCoordinator.phase == .awaitingReview,
            "The model repair did not pass validation and reach review"
        )
        try expect(
            RunCoordinatorWorkflow.approveCurrent(in: &project),
            "A verified E2E item could not be approved"
        )
        try expect(
            RunCoordinatorWorkflow.beginNext(in: &project) == .readyForFinalValidation,
            "The completed fixture did not request final validation"
        )
        let finalValidation = try await engine.validate(
            project: &project,
            rootPath: fixture.root.path
        )
        let completion = CreationLoopWorkflow.completed(in: &project)
        try expect(
            finalValidation.succeeded
                && completion.isReady
                && project.stage == .release
                && project.progress == 1,
            "Verified E2E work did not reach evidence-backed completion"
        )

        let report = ProductionE2EReport(
            model: identifier,
            totalSeconds: Date().timeIntervalSince(startedAt),
            firstGenerationSeconds: firstValidation.startedAt
                .timeIntervalSince(firstGeneration),
            repairGenerationSeconds: repairedValidation.startedAt
                .timeIntervalSince(repairGeneration),
            firstValidation: ProductionE2EEngine.summary(firstValidation),
            repairedValidation: ProductionE2EEngine.summary(repairedValidation),
            finalValidation: ProductionE2EEngine.summary(finalValidation),
            attemptedCycles: project.runCoordinator.attemptedCycleCount,
            approvedCycles: project.runCoordinator.approvedCycleCount,
            ledgerEvents: project.runCoordinator.records.map(\.event),
            completed: project.progress == 1
        )
        FileHandle.standardOutput.write(
            try JSONEncoder().encode(report) + Data("\n".utf8)
        )
        print("Production E2E completed with disposable source and local model.")
    }

}

private struct ProductionFixture {
    let root: URL
    private let manager = FileManager.default

    init() throws {
        root = manager.temporaryDirectory.appendingPathComponent(
            "Harness-Production-E2E-\(UUID().uuidString)",
            isDirectory: true
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
            try write(Self.tests, to: "Tests/GreetingTests/GreetingTests.swift")
        } catch {
            try? manager.removeItem(at: root)
            throw error
        }
    }

    func project(model: ModelSelection) -> HarnessProject {
        HarnessProject(
            name: "使い捨て制作E2E",
            summary: "保存済みワークスペースを使わない合成評価",
            targets: [.macOS],
            stage: .build,
            progress: 0.35,
            currentActivity: "E2E評価を準備しています",
            workItems: [
                WorkItem(
                    title: "挨拶を仕上げる",
                    detail: "検証結果を受けて正しい挨拶へ修正する",
                    status: .pending
                )
            ],
            activity: [],
            selectedModel: model,
            creationLoop: CreationLoopState(phase: .awaitingUserDecision)
        )
    }

    func remove() {
        guard root.lastPathComponent.hasPrefix("Harness-Production-E2E-") else { return }
        try? manager.removeItem(at: root)
    }

    private func write(_ text: String, to relativePath: String) throws {
        try Data(text.utf8).write(
            to: root.appendingPathComponent(relativePath),
            options: .atomic
        )
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
    """

    private static let tests = """
    import Testing
    @testable import Greeting

    @Test func greetingIsJapaneseHello() {
        #expect(greeting() == "こんにちは")
    }
    """
}

private struct ProductionE2EReport: Encodable {
    let model: String
    let totalSeconds: TimeInterval
    let firstGenerationSeconds: TimeInterval
    let repairGenerationSeconds: TimeInterval
    let firstValidation: [ValidationSummary]
    let repairedValidation: [ValidationSummary]
    let finalValidation: [ValidationSummary]
    let attemptedCycles: Int
    let approvedCycles: Int
    let ledgerEvents: [RunCoordinatorEvent]
    let completed: Bool
}
