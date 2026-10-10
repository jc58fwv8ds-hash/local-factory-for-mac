import HarnessCore
import HarnessExecution

extension FileChangeSession {
    func applyProposal() async -> AppliedFileChange? {
        guard let proposal, !isBusy, !isApplied else { return nil }
        isApplying = true
        errorMessage = nil
        var createdCheckpoint: GitFileCheckpoint?
        var primaryApplied = false
        do {
            createdCheckpoint = try await gitCheckpointProvider.create(
                rootPath: rootPath,
                proposal: proposal
            )
            try await editor.apply(rootPath: rootPath, proposal: proposal)
            primaryApplied = true
            try await applyRelated()
            let change = AppliedFileChange(
                proposal: proposal,
                checkpoint: createdCheckpoint
            )
            appliedChange = change
            isApplied = true
            repairProgress?.markCompleted(relativePath: proposal.relativePath)
            artifactPlan?.markCompleted(relativePath: proposal.relativePath)
            isApplying = false
            return change
        } catch {
            if error as? RecordedFileEditError == .needsInspection {
                hasUnresolvedEdit = true
                appliedChange = AppliedFileChange(proposal: proposal, checkpoint: createdCheckpoint)
            } else {
                // A related file failed after the primary applied: the change is all or nothing.
                if primaryApplied {
                    await revertRelated()
                    do { try await editor.revert(rootPath: rootPath, proposal: proposal) } catch { hasUnresolvedEdit = true }
                }
                if let createdCheckpoint { await gitCheckpointProvider.discard(createdCheckpoint) }
            }
            errorMessage = error.localizedDescription
            isApplying = false
            return nil
        }
    }

    /// Applies the other files of an orchestrated change after the primary one, each with its own checkpoint.
    private func applyRelated() async throws {
        appliedRelated = []
        for related in relatedProposals {
            let checkpoint = try await gitCheckpointProvider.create(rootPath: rootPath, proposal: related)
            do {
                try await editor.apply(rootPath: rootPath, proposal: related)
            } catch {
                if let checkpoint { await gitCheckpointProvider.discard(checkpoint) }
                throw error
            }
            appliedRelated.append((related, checkpoint))
        }
    }

    /// Reverts the related files in reverse order; failures are reported, never hidden.
    private func revertRelated() async {
        for (related, checkpoint) in appliedRelated.reversed() {
            do {
                try await editor.revert(rootPath: rootPath, proposal: related)
                if let checkpoint { await gitCheckpointProvider.discard(checkpoint) }
            } catch {
                hasUnresolvedEdit = true
                errorMessage = "関連ファイル \(related.relativePath) を元に戻せませんでした: \(error.localizedDescription)"
            }
        }
        appliedRelated = []
    }

    func revertAppliedProposal() async -> AppliedFileChange? {
        guard let proposal, isApplied, !isBusy else { return nil }
        let checkpoint = appliedChange?.checkpoint
        isApplying = true
        errorMessage = nil
        do {
            await revertRelated()
            try await editor.revert(rootPath: rootPath, proposal: proposal)
            if let checkpoint {
                await gitCheckpointProvider.discard(checkpoint)
            }
            isApplied = false
            if proposal.operation == .update {
                document = EditableSourceDocument(
                    relativePath: proposal.relativePath,
                    content: proposal.originalContent
                )
                proposedContent = proposal.originalContent
            }
            self.proposal = nil
            appliedChange = nil
            repairProgress?.markCurrentPending()
            artifactPlan?.markPending(relativePath: proposal.relativePath)
            validation.clearResult()
            presentationMode = .edit
            isApplying = false
            return AppliedFileChange(proposal: proposal, checkpoint: checkpoint)
        } catch {
            if error as? RecordedFileEditError == .needsInspection { hasUnresolvedEdit = true }
            errorMessage = error.localizedDescription
            isApplying = false
            return nil
        }
    }
}
