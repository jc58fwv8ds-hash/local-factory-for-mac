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
                var unreverted: [String] = []
                if primaryApplied {
                    unreverted = await revertRelated()
                    do { try await editor.revert(rootPath: rootPath, proposal: proposal) } catch {
                        hasUnresolvedEdit = true
                        unreverted.insert(proposal.relativePath, at: 0)
                    }
                }
                // The restore point stays while any file is still changed.
                if unreverted.isEmpty, let createdCheckpoint { await gitCheckpointProvider.discard(createdCheckpoint) }
                if !unreverted.isEmpty {
                    errorMessage = "適用できませんでした(\(error.localizedDescription))。次のファイルは元に戻せず、修正後のままです: "
                        + unreverted.joined(separator: "、")
                    isApplying = false
                    return nil
                }
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

    /// Reverts the related files in reverse order; failures are reported, never hidden. Returns the paths that could not be
    /// reverted; they stay in `appliedRelated` so a later revert retries them.
    private func revertRelated() async -> [String] {
        var stuck: [(FileChangeProposal, GitFileCheckpoint?)] = []
        for (related, checkpoint) in appliedRelated.reversed() {
            do {
                try await editor.revert(rootPath: rootPath, proposal: related)
                if let checkpoint { await gitCheckpointProvider.discard(checkpoint) }
            } catch {
                hasUnresolvedEdit = true
                stuck.insert((related, checkpoint), at: 0)
                errorMessage = "関連ファイル \(related.relativePath) を元に戻せませんでした: \(error.localizedDescription)"
            }
        }
        appliedRelated = stuck
        return stuck.map(\.0.relativePath)
    }

    func revertAppliedProposal() async -> AppliedFileChange? {
        guard let proposal, isApplied, !isBusy else { return nil }
        let checkpoint = appliedChange?.checkpoint
        isApplying = true
        errorMessage = nil
        do {
            // A related file that stays changed means the revert did not happen: report it, keep the change applied.
            let stuck = await revertRelated()
            guard stuck.isEmpty else {
                errorMessage = "次の関連ファイルを元に戻せなかったため、取り消しを止めました(主なファイルは修正後のままです): "
                    + stuck.joined(separator: "、")
                isApplying = false
                return nil
            }
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
