import Foundation

extension HarnessProject {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case summary
        case targets
        case stage
        case progress
        case currentActivity
        case workItems
        case activity
        case selectedModel
        case conversation
        case fileCheckpoints
        case repairResumeState
        case operationCheckpoint
        case computerOperationCheckpoint
        case creationLoop
        case artifactCreationPlan
        case runCoordinator
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            summary: try container.decode(String.self, forKey: .summary),
            targets: try container.decode([TargetPlatform].self, forKey: .targets),
            stage: try container.decode(ProjectStage.self, forKey: .stage),
            progress: try container.decode(Double.self, forKey: .progress),
            currentActivity: try container.decode(String.self, forKey: .currentActivity),
            workItems: try container.decode([WorkItem].self, forKey: .workItems),
            activity: try container.decode([ActivityEvent].self, forKey: .activity),
            selectedModel: try container.decodeIfPresent(ModelSelection.self, forKey: .selectedModel),
            conversation: try container.decodeIfPresent(
                [ConversationMessage].self,
                forKey: .conversation
            ) ?? [],
            fileCheckpoints: try container.decodeIfPresent(
                [GitFileCheckpoint].self,
                forKey: .fileCheckpoints
            ) ?? [],
            repairResumeState: try container.decodeIfPresent(
                RepairResumeState.self,
                forKey: .repairResumeState
            ),
            operationCheckpoint: try container.decodeIfPresent(
                ProjectOperationCheckpoint.self,
                forKey: .operationCheckpoint
            ),
            computerOperationCheckpoint: try container.decodeIfPresent(
                ComputerOperationCheckpoint.self,
                forKey: .computerOperationCheckpoint
            ),
            creationLoop: try container.decodeIfPresent(
                CreationLoopState.self,
                forKey: .creationLoop
            ) ?? CreationLoopState(),
            artifactCreationPlan: try container.decodeIfPresent(
                ArtifactCreationPlan.self,
                forKey: .artifactCreationPlan
            ),
            runCoordinator: try container.decodeIfPresent(
                RunCoordinatorState.self,
                forKey: .runCoordinator
            ) ?? RunCoordinatorState()
        )
        ProjectMilestoneProgress.reconcileCompletion(in: &self)
        RunCoordinatorWorkflow.recoverAfterRestart(in: &self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(summary, forKey: .summary)
        try container.encode(targets, forKey: .targets)
        try container.encode(stage, forKey: .stage)
        try container.encode(progress, forKey: .progress)
        try container.encode(currentActivity, forKey: .currentActivity)
        try container.encode(workItems, forKey: .workItems)
        try container.encode(activity, forKey: .activity)
        try container.encodeIfPresent(selectedModel, forKey: .selectedModel)
        try container.encode(conversation, forKey: .conversation)
        try container.encode(fileCheckpoints, forKey: .fileCheckpoints)
        try container.encodeIfPresent(repairResumeState, forKey: .repairResumeState)
        try container.encodeIfPresent(operationCheckpoint, forKey: .operationCheckpoint)
        try container.encodeIfPresent(
            computerOperationCheckpoint,
            forKey: .computerOperationCheckpoint
        )
        try container.encode(creationLoop, forKey: .creationLoop)
        try container.encodeIfPresent(artifactCreationPlan, forKey: .artifactCreationPlan)
        try container.encode(runCoordinator, forKey: .runCoordinator)
    }
}
