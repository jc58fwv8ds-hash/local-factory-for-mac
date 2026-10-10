import Foundation
import HarnessCore

enum RepairResumeChecks {
    static func run() throws {
        let diagnostics = [
            diagnostic(path: "Sources/App.swift", message: "private compiler detail"),
            diagnostic(path: "Sources/Helper.swift", message: "secret build output")
        ]
        guard let plan = BuildFailureAnalysis(
            diagnostics: diagnostics,
            unresolvedErrorCount: 0,
            failedKinds: [.build]
        ).repairPlan else {
            throw CheckFailure(description: "Repair plan was unexpectedly empty")
        }

        var project = HarnessProject.starter
        RepairResumeWorkflow.started(
            plan: plan,
            selectedTargetID: plan.targets[0].id,
            in: &project
        )
        var progress = BuildRepairProgress(plan: plan)
        progress.markCompleted(relativePath: "Sources/App.swift")
        _ = progress.select(relativePath: "Sources/Helper.swift")
        RepairResumeWorkflow.updated(progress: progress, in: &project)
        try expect(
            project.repairResumeState?.targetPaths == [
                "Sources/App.swift", "Sources/Helper.swift"
            ]
                && project.repairResumeState?.completedPaths == ["Sources/App.swift"]
                && project.repairResumeState?.currentPath == "Sources/Helper.swift",
            "Repair resume progress did not persist its bounded minimal state"
        )

        let encoded = try JSONEncoder().encode(project)
        let json = String(decoding: encoded, as: UTF8.self)
        try expect(
            !json.contains("private compiler detail")
                && !json.contains("secret build output")
                && !json.contains("diagnostics")
                && !json.contains("instruction"),
            "Repair resume persistence leaked diagnostic or instruction content"
        )
        let decoded = try JSONDecoder().decode(HarnessProject.self, from: encoded)
        try expect(
            decoded.repairResumeState == project.repairResumeState,
            "Repair resume state did not survive workspace encoding"
        )

        let legacyProject = HarnessProject.starter
        let legacyEncoded = try JSONEncoder().encode(legacyProject)
        let legacyJSON = String(decoding: legacyEncoded, as: UTF8.self)
        try expect(
            !legacyJSON.contains("repairResumeState"),
            "An empty repair resume state should not alter legacy workspace JSON"
        )
        let decodedLegacy = try JSONDecoder().decode(
            HarnessProject.self,
            from: legacyEncoded
        )
        try expect(
            decodedLegacy.repairResumeState == nil,
            "Legacy workspace JSON did not default repair resume state to nil"
        )

        let replacementTarget = BuildRepairTarget(
            relativePath: "Sources/Replacement.swift",
            diagnostics: [
                diagnostic(
                    path: "Sources/Replacement.swift",
                    message: "new compiler failure"
                )
            ]
        )
        let remainingPlan = BuildRepairPlan(
            targets: [replacementTarget],
            unresolvedErrorCount: 0
        )
        RepairResumeWorkflow.validationCompleted(
            report: failedReport(),
            freshPlan: remainingPlan,
            in: &project
        )
        try expect(
            project.repairResumeState?.completedCount == 1
                && project.repairResumeState?.pendingCount == 1
                && project.repairResumeState?.targetPaths == [
                    "Sources/App.swift", "Sources/Replacement.swift"
                ]
                && project.repairResumeState?.currentPath
                    == "Sources/Replacement.swift",
            "Failed revalidation did not replace stale pending paths"
        )
        RepairResumeWorkflow.validationCompleted(
            report: passingReport(),
            freshPlan: nil,
            in: &project
        )
        try expect(
            project.repairResumeState == nil,
            "Passing revalidation did not clear the repair resume state"
        )

        let unsafe = RepairResumeState(
            targetPaths: ["../Secret.swift", "/tmp/Outside.swift", "Sources/App.swift"],
            completedPaths: ["../Secret.swift", "Sources/App.swift"],
            currentPath: "/tmp/Outside.swift"
        )
        try expect(
            unsafe.targetPaths == ["Sources/App.swift"]
                && unsafe.completedPaths == ["Sources/App.swift"]
                && unsafe.currentPath == nil,
            "Repair resume state accepted unsafe persisted paths"
        )
        print("✓ Repair plans resume without persisting logs, prompts, or unsafe paths")
    }

    private static func diagnostic(
        path: String,
        message: String
    ) -> BuildFailureDiagnostic {
        BuildFailureDiagnostic(
            validationKind: .build,
            relativePath: path,
            line: 1,
            column: 1,
            message: message
        )
    }

    private static func failedReport() -> ProjectValidationReport {
        report(succeeded: false)
    }

    private static func passingReport() -> ProjectValidationReport {
        report(succeeded: true)
    }

    private static func report(succeeded: Bool) -> ProjectValidationReport {
        ProjectValidationReport(
            startedAt: .now,
            finishedAt: .now,
            checks: [
                ProjectValidationCheck(
                    kind: .build,
                    succeeded: succeeded,
                    exitCode: succeeded ? 0 : 1,
                    output: succeeded ? "ok" : "failed",
                    outputWasTruncated: false,
                    duration: 0.1
                )
            ]
        )
    }
}
