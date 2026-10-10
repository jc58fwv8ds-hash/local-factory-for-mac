import Foundation
import HarnessCore
import Testing

struct ValidationFailureClassificationTests {
    @Test func safeSourceDiagnosticPermitsCodeRepair() {
        let assessment = classify(
            kind: .build,
            output: "Sources/App.swift:12:4: error: cannot find 'value' in scope",
            analysis: sourceAnalysis()
        )

        #expect(assessment.domain == .implementation)
        #expect(assessment.permitsCodeChanges)
    }

    @Test func failedTestWithoutEnvironmentMarkersPermitsRepair() {
        let assessment = classify(kind: .test, output: "Test run failed")

        #expect(assessment.domain == .testBehavior)
        #expect(assessment.permitsCodeChanges)
    }

    @Test(arguments: [
        ("xcrun: error: invalid active developer path", ValidationFailureDomain.toolchain),
        ("Unable to find a destination matching iPhone Simulator", .simulator),
        ("Signing requires a development team", .signing),
        ("failed to clone repository: could not resolve host", .dependency),
        ("write failed: no space left on device", .resources)
    ])
    func environmentFailuresBlockCodeChanges(
        output: String,
        expected: ValidationFailureDomain
    ) {
        let assessment = classify(kind: .xcodeBuild, output: output)

        #expect(assessment.domain == expected)
        #expect(!assessment.permitsCodeChanges)
    }

    @Test func environmentSignalInsideATestIsNotMistakenForATestBug() {
        let assessment = classify(
            kind: .xcodeTest,
            output: "[Harness] 利用できるiPhone Simulatorがありません。"
        )

        #expect(assessment.domain == .simulator)
        #expect(!assessment.permitsCodeChanges)
    }

    @Test func sourceAndEnvironmentEvidenceBecomeMixedAndBlockRepair() {
        let assessment = classify(
            kind: .build,
            output: "Sources/App.swift:1:1: error: missing value\nno space left on device",
            analysis: sourceAnalysis()
        )

        #expect(assessment.domain == .mixed)
        #expect(!assessment.permitsCodeChanges)
    }

    @Test func unknownBuildFailureStaysConservative() {
        let assessment = classify(kind: .build, output: "emit-module command failed")

        #expect(assessment.domain == .unknown)
        #expect(!assessment.permitsCodeChanges)
    }

    @Test func dependencySourceDiagnosticNeedsSafeProjectAnalysis() {
        let assessment = classify(
            kind: .build,
            output: ".build/checkouts/Library/Sources/Library.swift:4:1: error: unavailable"
        )

        #expect(assessment.domain == .unknown)
        #expect(!assessment.permitsCodeChanges)
    }

    @Test func environmentFailureCannotCreateAnAIReplanContext() {
        let project = HarnessProject(
            name: "分類テスト",
            summary: "",
            targets: [.macOS],
            stage: .build,
            progress: 0.4,
            currentActivity: "検証失敗",
            workItems: [WorkItem(
                title: "画面を作る",
                detail: "表示できる",
                status: .pending
            )],
            activity: []
        )

        #expect(throws: WorkPlanReplanError.failureRequiresRecovery) {
            try WorkPlanReplanContextBuilder.make(
                project: project,
                report: report(
                    kind: .xcodeBuild,
                    output: "xcrun: error: invalid active developer path"
                ),
                analysis: nil
            )
        }
    }

    @Test func environmentFailureKeepsCoordinatorAtRevalidation() {
        let item = WorkItem(
            title: "画面を作る",
            detail: "表示できる",
            status: .pending
        )
        var project = HarnessProject(
            name: "分類テスト",
            summary: "",
            targets: [.macOS],
            stage: .build,
            progress: 0.4,
            currentActivity: "検証失敗",
            workItems: [item],
            activity: [],
            runCoordinator: RunCoordinatorState(
                phase: .awaitingValidation,
                currentWorkItemID: item.id,
                attemptedCycleCount: 1
            )
        )
        let failure = report(
            kind: .xcodeBuild,
            output: "write failed: no space left on device"
        )

        RunCoordinatorWorkflow.recordedValidation(failure, in: &project)
        RunCoordinatorWorkflow.recordedValidation(failure, in: &project)

        #expect(project.runCoordinator.phase == .awaitingValidation)
        #expect(project.runCoordinator.stopReason == nil)
        #expect(project.runCoordinator.consecutiveMatchingFailures == 2)
    }

    @Test func unverifiedCompilerTextKeepsCoordinatorAtRevalidation() {
        let item = WorkItem(
            title: "画面を作る",
            detail: "表示できる",
            status: .pending
        )
        var project = HarnessProject(
            name: "分類テスト",
            summary: "",
            targets: [.macOS],
            stage: .build,
            progress: 0.4,
            currentActivity: "検証失敗",
            workItems: [item],
            activity: [],
            runCoordinator: RunCoordinatorState(
                phase: .awaitingValidation,
                currentWorkItemID: item.id,
                attemptedCycleCount: 1
            )
        )
        let failure = report(
            kind: .build,
            output: ".build/checkouts/Library/Sources/Library.swift:4:1: error: unavailable"
        )

        RunCoordinatorWorkflow.recordedValidation(failure, in: &project)

        #expect(project.runCoordinator.phase == .awaitingValidation)
        #expect(project.runCoordinator.stopReason == nil)
    }

    private func classify(
        kind: ProjectValidationKind,
        output: String,
        analysis: BuildFailureAnalysis? = nil
    ) -> ValidationFailureAssessment {
        ValidationFailureClassifier.classify(
            report: report(kind: kind, output: output),
            analysis: analysis
        )
    }

    private func report(
        kind: ProjectValidationKind,
        output: String
    ) -> ProjectValidationReport {
        ProjectValidationReport(
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            checks: [ProjectValidationCheck(
                kind: kind,
                succeeded: false,
                exitCode: 1,
                output: output,
                outputWasTruncated: false,
                duration: 1
            )]
        )
    }

    private func sourceAnalysis() -> BuildFailureAnalysis {
        BuildFailureAnalysis(
            diagnostics: [BuildFailureDiagnostic(
                validationKind: .build,
                relativePath: "Sources/App.swift",
                line: 12,
                column: 4,
                message: "cannot find value"
            )],
            unresolvedErrorCount: 0,
            failedKinds: [.build]
        )
    }
}
