import Foundation
import HarnessCore

/// Moving through a plan of files, new ones written and existing ones rewritten (2026-11-10: a plan may now rewrite an
/// existing file, such as the ContentView a new screen must be shown from).
extension FileChangeSession {
    func continueToNextArtifactTarget() async {
        guard canContinueArtifactPlan else { return }
        isApplied = false
        proposal = nil
        appliedChange = nil
        _ = artifactPlan?.advance()
        await prepareCurrentArtifactTarget()
    }

    func prepareCurrentArtifactTarget() async {
        guard let target = artifactPlan?.currentTarget else { return }
        isApplied = false
        if files.contains(where: { $0.relativePath == target.relativePath }) {
            await select(target.relativePath)
            aiInstruction = target.instruction
            return
        }
        beginNewFile()
        newFileRelativePath = target.relativePath
        aiInstruction = target.instruction
    }
}
