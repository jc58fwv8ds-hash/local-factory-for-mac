import Foundation
import HarnessCore

struct ProductionE2EEngine {
    let model: ModelSelection
    private let inference: any ModelInferenceProvider
    private let editor: any ProjectFileEditing
    private let validator: any ProjectValidating

    init(
        model: ModelSelection,
        inference: any ModelInferenceProvider = LocalInferenceService(),
        editor: any ProjectFileEditing = ProjectFileEditor(),
        validator: any ProjectValidating = LocalProjectValidationService(
            disableSwiftPMSandbox: true
        )
    ) {
        self.model = model
        self.inference = inference
        self.editor = editor
        self.validator = validator
    }

    func applyModelEdit(
        instruction: String,
        project: inout HarnessProject,
        rootPath: String,
        targetPath: String
    ) async throws {
        ProjectFileEditInferenceWorkflow.started(instruction: instruction, in: &project)
        let document = try await editor.load(rootPath: rootPath, relativePath: targetPath)
        let request = InferenceRequest(
            runtime: model.runtime,
            modelIdentifier: model.identifier,
            messages: try FileEditPromptBuilder.messages(
                document: document,
                instruction: instruction
            ),
            maximumOutputTokens: InferenceOutputBudget.fileChange,
            structuredOutput: .fileContent
        )
        let response = try await collect(request)
        let content = try FileEditResponseParser.proposedContent(from: response)
        let proposal = try await editor.makeProposal(
            document: document,
            proposedContent: content
        )
        ProjectFileEditInferenceWorkflow.proposalReady(in: &project)
        try await editor.apply(rootPath: rootPath, proposal: proposal)
        _ = ProjectFileChangeWorkflow.applied(proposal: proposal, in: &project)
        RunCoordinatorWorkflow.recordedChange(in: &project)
    }

    func validate(
        project: inout HarnessProject,
        rootPath: String
    ) async throws -> ProjectValidationReport {
        CreationLoopWorkflow.startedValidation(in: &project)
        let report = try await validator.validate(rootPath: rootPath)
        ProjectValidationWorkflow.completed(report: report, in: &project)
        RunCoordinatorWorkflow.recordedValidation(
            report,
            analysis: BuildFailureAnalyzer.analyze(
                report: report,
                rootPath: rootPath
            ),
            in: &project
        )
        return report
    }

    static func selected(
        _ decision: RunCoordinatorDecision
    ) throws -> RunCoordinatorWorkSelection {
        guard case .selected(let selection) = decision else {
            throw CheckFailure(description: "Expected a selected production item")
        }
        return selection
    }

    static func summary(
        _ report: ProjectValidationReport
    ) -> [ValidationSummary] {
        report.checks.map {
            ValidationSummary(
                kind: $0.kind,
                succeeded: $0.succeeded,
                exitCode: $0.exitCode,
                seconds: $0.duration
            )
        }
    }

    private func collect(_ request: InferenceRequest) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var output = ""
                for try await part in await inference.events(for: request) {
                    try Task.checkCancellation()
                    guard output.count + part.count <= 80_000 else {
                        throw InferenceError.invalidResponse
                    }
                    output += part
                }
                try Task.checkCancellation()
                return output
            }
            group.addTask {
                try await Task.sleep(for: .seconds(300))
                throw CheckFailure(
                    description: "Production E2E inference exceeded 300 seconds"
                )
            }
            defer { group.cancelAll() }
            return try await require(group.next())
        }
    }
}

struct ValidationSummary: Encodable {
    let kind: ProjectValidationKind
    let succeeded: Bool
    let exitCode: Int32
    let seconds: TimeInterval
}
