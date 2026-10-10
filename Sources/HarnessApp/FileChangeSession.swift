import Foundation
import HarnessCore
import Observation

enum FileChangePresentationMode: String, CaseIterable, Identifiable {
    case edit = "編集案"
    case diff = "差分"

    var id: String { rawValue }
}

enum FileEditGenerationEvent {
    case started(String)
    case proposalReady
    case cancelled
    case failed(String)
}

@MainActor
@Observable
final class FileChangeSession {
    let rootPath: String
    let model: ModelSelection?
    var files: [EditableSourceFile] = []
    var selectedPath: String?
    var document: EditableSourceDocument?
    var isCreatingNewFile = false
    var newFileRelativePath = ""
    var proposedContent = ""
    var aiInstruction = ""
    var proposal: FileChangeProposal? {
        didSet { if proposal == nil { relatedProposals = [] } }
    }
    /// Other files of the same orchestrated change (package scope). Reviewed with `proposal`, applied and reverted together.
    var relatedProposals: [FileChangeProposal] = []
    @ObservationIgnored var appliedRelated: [(FileChangeProposal, GitFileCheckpoint?)] = []
    var presentationMode: FileChangePresentationMode = .edit
    var isLoading = false
    var isGenerating = false
    var isApplying = false
    var isApplied = false
    var hasUnresolvedEdit = false
    var shouldValidateAfterApply = true
    var errorMessage: String?
    var repairProgress: BuildRepairProgress?
    var artifactPlan: ArtifactCreationPlan?
    var orchestratedOutcome: OrchestratedEditOutcome?
    let validation: ProjectValidationSession

    @ObservationIgnored let editor: any ProjectFileEditing
    @ObservationIgnored let gitCheckpointProvider: any GitCheckpointing
    @ObservationIgnored let inferenceProvider: any ModelInferenceProvider
    @ObservationIgnored let orchestrator: (any OrchestratedEditing)?
    @ObservationIgnored private let initialRelativePath: String?
    @ObservationIgnored let onGenerationEvent: (FileEditGenerationEvent) -> Void
    @ObservationIgnored var generationTask: Task<Void, Never>?
    @ObservationIgnored var appliedChange: AppliedFileChange?

    init(
        rootPath: String,
        model: ModelSelection?,
        editor: any ProjectFileEditing,
        gitCheckpointProvider: any GitCheckpointing,
        inferenceProvider: any ModelInferenceProvider,
        validationProvider: any ProjectValidating,
        initialRelativePath: String? = nil,
        initialInstruction: String = "",
        repairPlan: BuildRepairPlan? = nil,
        currentRepairTargetID: String? = nil,
        artifactPlan: ArtifactCreationPlan? = nil,
        orchestrator: (any OrchestratedEditing)? = nil,
        onGenerationEvent: @escaping (FileEditGenerationEvent) -> Void
    ) {
        self.orchestrator = orchestrator
        self.rootPath = rootPath
        self.model = model
        self.editor = editor
        self.gitCheckpointProvider = gitCheckpointProvider
        self.inferenceProvider = inferenceProvider
        self.initialRelativePath = initialRelativePath
        self.onGenerationEvent = onGenerationEvent
        aiInstruction = initialInstruction
        repairProgress = repairPlan.map {
            BuildRepairProgress(plan: $0, startingTargetID: currentRepairTargetID)
        }
        var resumedArtifactPlan = artifactPlan
        resumedArtifactPlan?.resumePendingTarget()
        self.artifactPlan = resumedArtifactPlan
        validation = ProjectValidationSession(
            rootPath: rootPath,
            provider: validationProvider
        )
    }

    var isBusy: Bool {
        isLoading || isGenerating || isApplying || validation.isRunning || hasUnresolvedEdit
    }

    var canAskAI: Bool {
        model != nil
            && (document != nil || hasNewFilePath)
            && !aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isBusy
            && !isApplied
    }

    var canReview: Bool {
        let hasChange = isCreatingNewFile
            ? hasNewFilePath && !proposedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : document.map { proposedContent != $0.content } ?? false
        return hasChange && !isBusy && !isApplied
    }

    var hasNewFilePath: Bool {
        !newFileRelativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var currentRepairTarget: BuildRepairTarget? {
        repairProgress?.currentTarget
    }

    var nextRepairTarget: BuildRepairTarget? {
        repairProgress?.nextTarget
    }

    var repairPlan: BuildRepairPlan? {
        repairProgress?.plan
    }

    var completedRepairTargetIDs: Set<String> {
        repairProgress?.completedTargetIDs ?? []
    }

    var canContinueRepairPlan: Bool {
        isApplied
            && !isBusy
            && nextRepairTarget != nil
            && validation.report?.succeeded != true
    }

    var canContinueArtifactPlan: Bool {
        isApplied && !isBusy && artifactPlan?.nextTarget != nil
    }

    func loadFiles() async {
        isLoading = true
        errorMessage = nil
        await validation.detectSupport()
        do {
            let loadedFiles = try await editor.editableFiles(rootPath: rootPath)
            files = loadedFiles
            if artifactPlan != nil {
                isLoading = false
                prepareCurrentArtifactTarget()
                return
            }
            let initialFile = initialRelativePath.flatMap { relativePath in
                loadedFiles.first { $0.relativePath == relativePath }
            }
            if let selectedFile = initialFile ?? loadedFiles.first {
                await select(selectedFile.relativePath)
            }
            if let initialRelativePath, initialFile == nil {
                errorMessage = "解析した対象（\(initialRelativePath)）は現在の編集可能一覧にありません。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func select(_ relativePath: String) async {
        guard (!isBusy || isLoading), !isApplied else { return }
        let loadingFiles = isLoading
        if !loadingFiles { isLoading = true }
        errorMessage = nil
        do {
            let loadedDocument = try await editor.load(
                rootPath: rootPath,
                relativePath: relativePath
            )
            selectedPath = relativePath
            document = loadedDocument
            isCreatingNewFile = false
            newFileRelativePath = ""
            if let target = repairProgress?.select(relativePath: relativePath) {
                aiInstruction = target.instruction
            }
            proposedContent = loadedDocument.content
            proposal = nil
            appliedChange = nil
            isApplied = false
            validation.clearResult()
            presentationMode = .edit
        } catch {
            errorMessage = error.localizedDescription
        }
        if !loadingFiles { isLoading = false }
    }

    func updateProposedContent(_ content: String) {
        guard !isApplied else { return }
        proposedContent = content
        proposal = nil
        if presentationMode == .diff {
            presentationMode = .edit
        }
    }

    func beginNewFile() {
        guard !isBusy, !isApplied else { return }
        selectedPath = nil
        document = nil
        isCreatingNewFile = true
        newFileRelativePath = ""
        proposedContent = ""
        aiInstruction = ""
        proposal = nil
        appliedChange = nil
        validation.clearResult()
        presentationMode = .edit
        errorMessage = nil
    }

    func startArtifactPlan(_ plan: ArtifactCreationPlan) {
        guard !isBusy, !isApplied, !plan.targets.isEmpty else { return }
        repairProgress = nil
        artifactPlan = plan
        prepareCurrentArtifactTarget()
    }

    func updateNewFileRelativePath(_ relativePath: String) {
        guard isCreatingNewFile, !isBusy, !isApplied else { return }
        newFileRelativePath = relativePath
        proposal = nil
        if presentationMode == .diff {
            presentationMode = .edit
        }
    }

    func resetProposal() {
        guard !isBusy, !isApplied else { return }
        if isCreatingNewFile {
            proposedContent = ""
        } else if let document {
            proposedContent = document.content
        } else {
            return
        }
        proposal = nil
        presentationMode = .edit
        errorMessage = nil
    }

    func prepareReview() async {
        guard !isBusy, !isApplied else { return }
        errorMessage = nil
        do {
            if isCreatingNewFile {
                proposal = try await editor.makeCreationProposal(
                    rootPath: rootPath,
                    relativePath: newFileRelativePath.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    proposedContent: proposedContent
                )
            } else if let document {
                proposal = try await editor.makeProposal(
                    document: document,
                    proposedContent: proposedContent
                )
            }
            presentationMode = .diff
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startPostEditValidation(
        automatically: Bool = true,
        onStart: @escaping @MainActor () -> Void,
        onComplete: @escaping @MainActor @Sendable (ProjectValidationReport) -> Void
    ) {
        guard !hasUnresolvedEdit else { return }
        if artifactPlan?.nextTarget != nil { return }
        let requiresFinalArtifactValidation = artifactPlan?.isFullyApplied == true
        guard (!automatically || shouldValidateAfterApply || requiresFinalArtifactValidation),
              validation.isSupported else { return }
        if automatically {
            validation.startAutomatically(onStart: onStart, onComplete: onComplete)
        } else if !validation.isRunning {
            onStart()
            validation.start(onComplete: onComplete)
        }
    }

    func stopAll() {
        generationTask?.cancel()
        validation.stop()
    }

    func continueToNextRepairTarget() async {
        guard canContinueRepairPlan, let nextRepairTarget else { return }
        isApplied = false
        proposal = nil
        appliedChange = nil
        _ = repairProgress?.select(relativePath: nextRepairTarget.relativePath)
        aiInstruction = nextRepairTarget.instruction
        await select(nextRepairTarget.relativePath)
    }

    func continueToNextArtifactTarget() {
        guard canContinueArtifactPlan else { return }
        isApplied = false
        proposal = nil
        appliedChange = nil
        _ = artifactPlan?.advance()
        prepareCurrentArtifactTarget()
    }

    private func prepareCurrentArtifactTarget() {
        guard let target = artifactPlan?.currentTarget else { return }
        isApplied = false
        beginNewFile()
        newFileRelativePath = target.relativePath
        aiInstruction = target.instruction
    }

}
