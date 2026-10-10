import Foundation
import HarnessCore

enum ProjectOperationCheckpointChecks {
    static func run() throws {
        let firstStart = Date(timeIntervalSince1970: 1_000)
        let resumedAt = Date(timeIntervalSince1970: 2_000)
        let workItemID = UUID()
        var project = HarnessProject.starter

        ProjectOperationCheckpointWorkflow.started(
            .projectValidation,
            in: &project,
            now: firstStart
        )
        ProjectOperationCheckpointWorkflow.started(
            .projectValidation,
            in: &project,
            now: resumedAt
        )
        try expect(
            project.operationCheckpoint == ProjectOperationCheckpoint(
                operation: .projectValidation,
                startedAt: firstStart,
                updatedAt: resumedAt
            ),
            "Resuming validation did not preserve its original start time"
        )

        ProjectOperationCheckpointWorkflow.started(
            .modelInference,
            referenceID: workItemID,
            in: &project,
            now: resumedAt
        )
        try expect(
            project.operationCheckpoint == ProjectOperationCheckpoint(
                operation: .modelInference,
                referenceID: workItemID,
                startedAt: resumedAt,
                updatedAt: resumedAt
            ),
            "A different operation did not replace the previous checkpoint"
        )

        ProjectOperationCheckpointWorkflow.started(
            .fileEditInference,
            in: &project,
            now: resumedAt
        )
        try expect(
            project.operationCheckpoint?.operation == .fileEditInference
                && project.operationCheckpoint?.referenceID == nil,
            "File-edit inference did not use the shared minimal checkpoint"
        )

        ProjectOperationCheckpointWorkflow.started(
            .artifactPlanning,
            in: &project,
            now: resumedAt
        )
        try expect(
            project.operationCheckpoint?.operation == .artifactPlanning
                && project.operationCheckpoint?.referenceID == nil,
            "Artifact planning did not use the shared minimal checkpoint"
        )

        let encoded = try JSONEncoder().encode(project)
        let json = String(decoding: encoded, as: UTF8.self)
        try expect(
            !json.contains("swift build")
                && !json.contains("diagnostics")
                && !json.contains("rootPath"),
            "Operation checkpoint persistence leaked commands, logs, or paths"
        )
        let decoded = try JSONDecoder().decode(HarnessProject.self, from: encoded)
        try expect(
            decoded.operationCheckpoint == project.operationCheckpoint,
            "Operation checkpoint did not survive workspace encoding"
        )

        ProjectOperationCheckpointWorkflow.completed(
            .artifactPlanning,
            in: &project
        )
        try expect(
            project.operationCheckpoint == nil,
            "Completed operation did not clear its checkpoint"
        )

        let legacyProject = HarnessProject.starter
        let legacyEncoded = try JSONEncoder().encode(legacyProject)
        let legacyJSON = String(decoding: legacyEncoded, as: UTF8.self)
        try expect(
            !legacyJSON.contains("operationCheckpoint"),
            "Empty operation state should not alter legacy workspace JSON"
        )
        let decodedLegacy = try JSONDecoder().decode(
            HarnessProject.self,
            from: legacyEncoded
        )
        try expect(
            decodedLegacy.operationCheckpoint == nil,
            "Legacy workspace JSON did not default operation checkpoint to nil"
        )

        print("✓ Interrupted operations use minimal checkpoints without logs or paths")
    }
}
