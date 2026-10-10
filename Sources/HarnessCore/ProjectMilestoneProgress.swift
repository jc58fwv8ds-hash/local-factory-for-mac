import Foundation

public enum ProjectMilestone: Sendable {
    case localWorkStarted
    case proposalReady
    case validationStarted
    case validationCompleted(succeeded: Bool)
    case completed
}

public enum ProjectMilestoneProgress {
    public static func reconcileCompletion(in project: inout HarnessProject) {
        guard project.creationLoop.phase == .completed else { return }
        record(.completed, in: &project)
    }

    public static func record(
        _ milestone: ProjectMilestone,
        in project: inout HarnessProject
    ) {
        switch milestone {
        case .localWorkStarted:
            advance(&project, to: .build, progress: 0.35)
        case .proposalReady:
            advance(&project, to: .build, progress: 0.55)
        case .validationStarted:
            advance(&project, to: .test, progress: 0.70)
        case .validationCompleted(let succeeded):
            if succeeded {
                advance(&project, to: .finish, progress: 0.90)
            } else {
                advance(&project, to: .test, progress: 0.75)
            }
        case .completed:
            project.stage = .release
            project.progress = 1
        }
    }

    private static func advance(
        _ project: inout HarnessProject,
        to stage: ProjectStage,
        progress: Double
    ) {
        if project.stage.ordinal < stage.ordinal {
            project.stage = stage
        }
        project.progress = max(project.progress, progress)
    }
}
