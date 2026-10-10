import Foundation

public enum ProjectFileChangeWorkflow {
    @discardableResult
    public static func applied(
        proposal: FileChangeProposal,
        checkpoint: GitFileCheckpoint? = nil,
        in project: inout HarnessProject
    ) -> GitFileCheckpoint? {
        CreationLoopWorkflow.localProposalReady(in: &project)
        CreationCompletionPolicy.invalidateValidationEvidence(in: &project)
        project.currentActivity = proposal.operation == .creation
            ? "\(proposal.relativePath)を新規作成しました"
            : "\(proposal.relativePath)の変更を適用しました"
        project.activity.insert(
            ActivityEvent(
                title: proposal.operation == .creation
                    ? "レビュー済みのファイルを作成しました"
                    : "レビュー済みの変更を適用しました",
                detail: detail(for: proposal, checkpoint: checkpoint),
                kind: .change
            ),
            at: 0
        )
        if let checkpoint {
            project.fileCheckpoints.insert(checkpoint, at: 0)
            if project.fileCheckpoints.count > 20 {
                return project.fileCheckpoints.removeLast()
            }
        }
        return nil
    }

    public static func reverted(
        proposal: FileChangeProposal,
        checkpoint: GitFileCheckpoint? = nil,
        in project: inout HarnessProject
    ) {
        CreationCompletionPolicy.invalidateValidationEvidence(in: &project)
        project.currentActivity = proposal.operation == .creation
            ? "\(proposal.relativePath)の作成を元に戻しました"
            : "\(proposal.relativePath)の変更を元に戻しました"
        project.activity.insert(
            ActivityEvent(
                title: proposal.operation == .creation
                    ? "新規ファイルの作成を元に戻しました"
                    : "ファイル変更を元に戻しました",
                detail: proposal.relativePath,
                kind: .verification
            ),
            at: 0
        )
        if let checkpoint {
            project.fileCheckpoints.removeAll { $0.id == checkpoint.id }
        }
    }

    public static func restored(
        checkpoint: GitFileCheckpoint,
        in project: inout HarnessProject
    ) {
        CreationCompletionPolicy.invalidateValidationEvidence(in: &project)
        project.currentActivity = "\(checkpoint.relativePath)をGit復元ポイントへ戻しました"
        project.fileCheckpoints.removeAll { $0.id == checkpoint.id }
        project.activity.insert(
            ActivityEvent(
                title: "Git復元ポイントから戻しました",
                detail: "\(checkpoint.relativePath) ・ \(checkpoint.shortObjectID)",
                kind: .verification
            ),
            at: 0
        )
    }

    private static func detail(
        for proposal: FileChangeProposal,
        checkpoint: GitFileCheckpoint?
    ) -> String {
        let change = "\(proposal.relativePath) ・ +\(proposal.summary.addedLineCount) / -\(proposal.summary.removedLineCount)"
        guard let checkpoint else { return change }
        return "\(change) ・ Git復元ポイント \(checkpoint.shortObjectID)"
    }
}
