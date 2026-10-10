import Foundation
import HarnessCore

struct FileEditContext: Identifiable {
    let id = UUID()
    let projectID: UUID
    let rootPath: String
    let model: ModelSelection?
    let initialRelativePath: String?
    let initialInstruction: String
    let repairPlan: BuildRepairPlan?
    let currentRepairTargetID: String?
    let artifactPlan: ArtifactCreationPlan?
}

struct ValidationContext: Identifiable {
    let id = UUID()
    let projectID: UUID
    let rootPath: String
    let model: ModelSelection?
    let startsAutomatically: Bool
}

struct RestoreContext: Identifiable {
    var id: UUID { projectID }
    let projectID: UUID
    let checkpoints: [GitFileCheckpoint]
}

struct ExternalReviewContext: Identifiable {
    let id = UUID()
    let projectID: UUID
    let rootPath: String
    let report: ProjectValidationReport
    let analysis: BuildFailureAnalysis?
}

struct PhysicalDeviceContext: Identifiable {
    let id = UUID()
    let rootPath: String
}
