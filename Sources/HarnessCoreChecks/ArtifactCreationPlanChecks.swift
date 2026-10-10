import Foundation
import HarnessCore

enum ArtifactCreationPlanChecks {
    static func run() throws {
        try checkPromptAndParser()
        try checkPlanProgressAndPersistence()
        try checkWorkflow()
        print("✓ Artifact plans coordinate bounded new files without batch writes")
    }

    private static func checkPromptAndParser() throws {
        let existing = ["Package.swift", "Sources/App.swift", "Tests/AppTests.swift"]
        let messages = try ArtifactPlanPromptBuilder.messages(
            instruction: "設定読込と検証を追加",
            existingPaths: existing
        )
        let json = #"{"files":[{"path":"Sources/Config.swift","instruction":"設定値型を作成"},{"path":"Tests/ConfigTests.swift","instruction":"設定値型のテストを作成"}]}"#
        let plan = try ArtifactPlanResponseParser.plan(
            from: "```json\n\(json)\n```",
            instruction: "設定読込と検証を追加",
            existingPaths: existing
        )
        try expect(
            messages.count == 2
                && messages[0].content.contains("2〜8ファイル")
                && messages[1].content.contains("Sources/App.swift")
                && messages[1].content.contains("作成可能フォルダ")
                && messages[1].content.contains("- Sources")
                && plan.targets.map(\.relativePath) == [
                    "Sources/Config.swift",
                    "Tests/ConfigTests.swift"
                ],
            "Artifact planning prompt or structured parser failed"
        )

        let invalidPayloads = [
            #"{"files":[{"path":"../Outside.swift","instruction":"x"},{"path":"Sources/B.swift","instruction":"y"}]}"#,
            #"{"files":[{"path":"Sources/A.swift","instruction":"x"},{"path":"Sources/A.swift","instruction":"y"}]}"#,
            #"{"files":[{"path":"Sources/A.swift","instruction":"x"},{"path":"sources/a.swift","instruction":"y"}]}"#,
            #"{"files":[{"path":"Sources/App.swift","instruction":"x"},{"path":"Sources/B.swift","instruction":"y"}]}"#,
            #"{"files":[{"path":"Sources/Only.swift","instruction":"x"}]}"#,
            #"{"files":[{"path":"New/A.swift","instruction":"x"},{"path":"Sources/B.swift","instruction":"y"}]}"#
        ]
        for payload in invalidPayloads {
            do {
                _ = try ArtifactPlanResponseParser.plan(
                    from: payload,
                    instruction: "invalid",
                    existingPaths: existing
                )
                throw CheckFailure(description: "Unsafe artifact plan was accepted")
            } catch is ArtifactPlanInferenceError {}
        }

        try expect(
            ArtifactPlanDirectoryPolicy.availableDirectories(
                from: ["Sources/App/Feature.swift", "README.md"]
            ) == [".", "Sources", "Sources/App"]
                && ArtifactPlanDirectoryPolicy.parentDirectory(of: "README.md") == ".",
            "Available artifact parent directories were not derived safely"
        )
    }

    private static func checkPlanProgressAndPersistence() throws {
        var plan = fixturePlan()
        try expect(
            plan.currentTarget?.relativePath == "Sources/Feature.swift"
                && plan.nextTarget?.relativePath == "Tests/FeatureTests.swift",
            "Artifact coordinator did not choose its first targets"
        )
        plan.markCompleted(relativePath: "Sources/Feature.swift")
        let encoded = try JSONEncoder().encode(plan)
        var decoded = try JSONDecoder().decode(ArtifactCreationPlan.self, from: encoded)
        try expect(
            decoded.completedCount == 1
                && decoded.currentTarget?.relativePath == "Tests/FeatureTests.swift",
            "Artifact plan did not resume at the first pending target"
        )
        decoded.markCompleted(relativePath: "Tests/FeatureTests.swift")
        try expect(decoded.isFullyApplied, "Artifact plan did not reach fully applied state")

        var project = HarnessProject.starter
        project.artifactCreationPlan = decoded
        let projectData = try JSONEncoder().encode(project)
        try expect(
            try JSONDecoder().decode(HarnessProject.self, from: projectData)
                .artifactCreationPlan == decoded,
            "Artifact plan did not survive workspace persistence"
        )

        let legacy = try JSONEncoder().encode(HarnessProject.starter)
        try expect(
            try JSONDecoder().decode(HarnessProject.self, from: legacy)
                .artifactCreationPlan == nil,
            "Legacy projects did not default artifact plan to nil"
        )
    }

    private static func checkWorkflow() throws {
        var project = HarnessProject.starter
        ArtifactCreationPlanWorkflow.planningStarted(in: &project)
        try expect(
            project.operationCheckpoint?.operation == .artifactPlanning
                && project.creationLoop.phase == .localModelWorking,
            "Artifact planning did not use the shared minimal checkpoint"
        )
        ArtifactCreationPlanWorkflow.planningReady(in: &project)
        try expect(
            project.operationCheckpoint == nil
                && project.creationLoop.phase == .awaitingUserDecision,
            "Artifact planning completion left stale operation state"
        )

        var plan = fixturePlan()
        ArtifactCreationPlanWorkflow.started(plan: plan, in: &project)
        plan.markCompleted(relativePath: "Sources/Feature.swift")
        plan.markCompleted(relativePath: "Tests/FeatureTests.swift")
        ArtifactCreationPlanWorkflow.updated(plan: plan, in: &project)
        let report = ProjectValidationReport(
            startedAt: .now,
            finishedAt: .now,
            checks: [
                ProjectValidationCheck(
                    kind: .build,
                    succeeded: true,
                    exitCode: 0,
                    output: "Build complete",
                    outputWasTruncated: false,
                    duration: 0.1
                )
            ]
        )
        ArtifactCreationPlanWorkflow.validationCompleted(report: report, in: &project)
        try expect(
            project.artifactCreationPlan == nil
                && project.activity.first?.kind == .verification,
            "Final validation did not close the artifact plan"
        )

        ArtifactCreationPlanWorkflow.planningStarted(in: &project)
        ArtifactCreationPlanWorkflow.discardedInterruptedPlanning(in: &project)
        try expect(
            project.operationCheckpoint == nil
                && project.creationLoop.phase == .awaitingInstruction,
            "Interrupted artifact planning did not discard safely"
        )
    }

    private static func fixturePlan() -> ArtifactCreationPlan {
        ArtifactCreationPlan(
            instruction: "機能とテストを追加",
            targets: [
                ArtifactCreationTarget(
                    relativePath: "Sources/Feature.swift",
                    instruction: "Feature型を作成"
                ),
                ArtifactCreationTarget(
                    relativePath: "Tests/FeatureTests.swift",
                    instruction: "Feature型のテストを作成"
                )
            ]
        )
    }
}
