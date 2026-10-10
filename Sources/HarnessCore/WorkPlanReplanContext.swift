import Foundation

public enum WorkPlanReplanContextBuilder {
    public static func make(
        project: HarnessProject,
        report: ProjectValidationReport,
        analysis: BuildFailureAnalysis?
    ) throws -> WorkPlanReplanContext {
        guard !report.succeeded else { throw WorkPlanReplanError.validationSucceeded }
        let assessment = ValidationFailureClassifier.classify(
            report: report,
            analysis: analysis
        )
        guard assessment.permitsCodeChanges else {
            throw WorkPlanReplanError.failureRequiresRecovery
        }
        let candidates = ProjectInstructionContext.productionCandidates(in: project)
            .filter { $0.status != .completed }
        guard !candidates.isEmpty else { throw WorkPlanReplanError.noRemainingItems }
        guard candidates.count <= WorkPlanReplanContext.maximumExistingItems else {
            throw WorkPlanReplanError.tooManyExistingItems
        }
        let guidance = ValidationRevisionGuidanceBuilder.make(
            report: report,
            analysis: analysis
        )
        let failedKinds = report.checks
            .filter { !$0.succeeded }
            .map { $0.kind.displayName }
            .joined(separator: "、")
        let firstLocation = analysis?.primaryDiagnostic.map { diagnostic in
            diagnostic.line.map { "\(diagnostic.relativePath):\($0)" }
                ?? diagnostic.relativePath
        }
        let currentState = firstLocation.map {
            "\(failedKinds)が失敗しています。最初に確認する位置は\($0)です。"
        } ?? "\(failedKinds)が失敗しています。安全に特定できたエラー位置はありません。"
        let items = candidates.enumerated().map { index, item in
            WorkPlanReplanExistingItem(
                reference: "item-\(index + 1)",
                workItemID: item.id,
                title: item.title,
                detail: item.detail,
                status: item.status,
                isPinned: project.runCoordinator.currentWorkItemID == item.id
            )
        }
        let diagnostics: [String] = analysis.map { value in
            value.diagnostics.prefix(6).map { diagnostic in
                let location = diagnostic.line.map {
                    "\(diagnostic.relativePath):\($0)"
                } ?? diagnostic.relativePath
                return "\(diagnostic.validationKind.displayName) | \(location) | エラー位置を確認"
            }
        } ?? []
        return WorkPlanReplanContext(
            baselineFingerprint: WorkPlanFingerprint.make(project),
            items: items,
            currentState: currentState,
            proposedChange: guidance.proposedChange,
            expectedResult: guidance.expectedResult,
            diagnostics: diagnostics
        )
    }
}

enum WorkPlanFingerprint {
    static func make(_ project: HarnessProject) -> String {
        var value = "\(project.runCoordinator.phase.rawValue)|"
        value += project.runCoordinator.currentWorkItemID?.uuidString ?? "none"
        for item in project.workItems {
            value += "|\(item.id.uuidString)|\(item.status.rawValue)|"
            value += "\(item.responseToMessageID?.uuidString ?? "production")|"
            value += "\(item.title)|\(item.detail)"
        }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
