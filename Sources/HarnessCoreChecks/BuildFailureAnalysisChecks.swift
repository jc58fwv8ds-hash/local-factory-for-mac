import Foundation
import HarnessCore

enum BuildFailureAnalysisChecks {
    static func run() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessFailureAnalysis-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("Sources/App", isDirectory: true),
            withIntermediateDirectories: true
        )
        let sourceURL = rootURL.appendingPathComponent("Sources/App/Main.swift")
        try Data("func launch() {}\n".utf8).write(to: sourceURL)
        let helperURL = rootURL.appendingPathComponent("Sources/App/Helper.swift")
        try Data("func assist() {}\n".utf8).write(to: helperURL)

        let output = """
        \(sourceURL.path):12:7: error: cannot find 'missing' in scope
        Sources/App/Main.swift:18: error: expected expression
        Sources/App/Helper.swift:4:2: error: missing return in global function
        \(sourceURL.path):12:7: error: cannot find 'missing' in scope
        /private/tmp/Outside.swift:1:1: error: outside root
        ../Secrets.swift:2:3: error: traversal
        """
        let analysis = BuildFailureAnalyzer.analyze(
            report: failedReport(output: output),
            rootPath: rootURL.path
        )
        try expect(
            analysis?.diagnostics.count == 3
                && analysis?.diagnostics[0].relativePath == "Sources/App/Main.swift"
                && analysis?.diagnostics[0].line == 12
                && analysis?.diagnostics[0].column == 7
                && analysis?.diagnostics[1].line == 18
                && analysis?.diagnostics[2].relativePath == "Sources/App/Helper.swift"
                && analysis?.unresolvedErrorCount == 2,
            "Failure analysis did not normalize, deduplicate, or contain paths safely"
        )
        try expect(
            analysis?.repairInstruction?.contains("対象ファイル: Sources/App/Main.swift") == true
                && analysis?.repairInstruction?.contains("行12") == true,
            "Failure analysis did not create a bounded repair instruction"
        )
        let plan = analysis?.repairPlan
        try expect(
            plan?.targets.map(\.relativePath) == [
                "Sources/App/Main.swift",
                "Sources/App/Helper.swift"
            ]
                && plan?.targets[0].diagnostics.count == 2
                && plan?.targets[1].instruction.contains("行4") == true,
            "Repair planning did not group files in first-diagnostic order"
        )
        if let plan {
            var progress = BuildRepairProgress(
                plan: plan,
                startingTargetID: "Sources/App/Helper.swift"
            )
            progress.markCompleted(relativePath: "Sources/App/Helper.swift")
            try expect(
                progress.completedCount == 1
                    && progress.nextTarget?.relativePath == "Sources/App/Main.swift",
                "Repair progress did not advance from a selected target deterministically"
            )
            _ = progress.select(relativePath: "Sources/App/Main.swift")
            progress.markCompleted(relativePath: "Sources/App/Helper.swift")
            try expect(
                progress.completedCount == 1,
                "Repair progress accepted completion for a non-current file"
            )
            progress.markCurrentPending()
            try expect(
                progress.completedTargetIDs == ["Sources/App/Helper.swift"],
                "Repair progress did not keep unrelated approved targets intact"
            )
        }

        let noTarget = BuildFailureAnalyzer.analyze(
            report: failedReport(output: "error: emit-module command failed\n"),
            rootPath: rootURL.path
        )
        try expect(
            noTarget?.diagnostics.isEmpty == true && noTarget?.repairInstruction == nil,
            "A global failure must not fabricate an editable target"
        )

        let passing = ProjectValidationReport(
            startedAt: .now,
            finishedAt: .now,
            checks: [
                ProjectValidationCheck(
                    kind: .build,
                    succeeded: true,
                    exitCode: 0,
                    output: "ok",
                    outputWasTruncated: false,
                    duration: 0.1
                )
            ]
        )
        try expect(
            BuildFailureAnalyzer.analyze(report: passing, rootPath: rootURL.path) == nil,
            "Passing validation must not produce a failure analysis"
        )
        print("✓ Build failures map only to safe editable project files")

        let environment = ValidationFailureClassifier.classify(
            report: failedReport(output: "xcrun: error: invalid active developer path"),
            analysis: nil
        )
        let mixed = ValidationFailureClassifier.classify(
            report: failedReport(output: "\(sourceURL.path):1:1: error: broken\nno space left on device"),
            analysis: analysis
        )
        let untrustedDependencySource = ValidationFailureClassifier.classify(
            report: failedReport(
                output: ".build/checkouts/Library/Sources/Library.swift:4:1: error: unavailable"
            ),
            analysis: nil
        )
        try expect(
            environment.domain == .toolchain
                && !environment.permitsCodeChanges
                && mixed.domain == .mixed
                && !mixed.permitsCodeChanges
                && untrustedDependencySource.domain == .unknown
                && !untrustedDependencySource.permitsCodeChanges,
            "Environment and mixed failures were allowed to start code repair"
        )
        print("✓ Environment failures cannot masquerade as code repair work")
    }

    private static func failedReport(output: String) -> ProjectValidationReport {
        ProjectValidationReport(
            startedAt: .now,
            finishedAt: .now,
            checks: [
                ProjectValidationCheck(
                    kind: .build,
                    succeeded: false,
                    exitCode: 1,
                    output: output,
                    outputWasTruncated: false,
                    duration: 0.2
                )
            ]
        )
    }
}
