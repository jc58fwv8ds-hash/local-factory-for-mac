import Foundation
import HarnessCore
import HarnessExecution
import Observation

enum StudioSection: String, CaseIterable, Identifiable {
    case home = "ホーム"
    case projects = "プロジェクト"
    case apps = "アプリ"
    case models = "AIモデル"
    case voices = "声"
    case developer = "開発"

    var id: String { rawValue }
}

struct WorkspaceNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case success
        case information
        case error
    }

    let id = UUID()
    let message: String
    let kind: Kind
}

enum GenerationPhase: Equatable {
    case idle
    case preparingSource
    case generating
    case revisingResponse
}

@MainActor
@Observable
final class WorkspaceStore {
    var selectedSection: StudioSection = .home
    var library: ProjectLibrary {
        didSet { synchronizeReplySuggestions() }
    }
    var instruction = ""
    var isShowingModelManager = false
    var isShowingNewProject = false
    var isShowingComputerOperator = false
    var showsDetails = false
    var notice: WorkspaceNotice?
    /// Code changes asked for in the chat, keyed by the asking message (not persisted; see WorkspaceStore+ChatChange).
    var chatChanges: [UUID: ChatChange] = [:]
    /// Documents attached in the chat for the next message (PDF, Word, Excel, CSV, text), read to text on attach.
    var documentAttachments: [DocumentText] = []
    /// A folder attached in the chat for file operations (bulk rename), and the rename cards by the asking message.
    var attachedFolder: URL?
    var renameChanges: [UUID: RenameChange] = [:]
    var spreadsheetChanges: [UUID: SpreadsheetChange] = [:]
    var analysisChanges: [UUID: AnalysisChange] = [:]
    var pdfChanges: [UUID: PDFChange] = [:]
    var wordChanges: [UUID: WordChange] = [:]
    /// What the next message is for (会話 / 文章を書く / 画像を作る), image cards, and a request waiting for consent.
    var composerPurpose: ComposerPurpose = .conversation
    var imageChanges: [UUID: ImageChange] = [:]
    var pendingConsent: PendingConsent?
    @ObservationIgnored var purposeSettingsOverride: PurposeModelSettings?
    @ObservationIgnored var imageGenerator: any ImageGenerating = ImageGenerationService()
    /// Tests inject the orchestrated run here; the App uses OrchestratedRunSettings.
    @ObservationIgnored var chatOrchestratorOverride: (any OrchestratedEditing)?
    var inspectingSourceProjectIDs = Set<UUID>()
    var sourceChangeSummaries: [UUID: SourceChangeSummary] = [:]
    var generationPhase: GenerationPhase = .idle
    var streamingResponse = ""
    var generationProjectID: UUID?
    var generationTimings: [InferenceResponseTiming] = []
    var lastConversationPerformance: ConversationPerformance?

    let runtimes: [RuntimeCandidate]
    let modelManager: ModelManagerStore
    let remoteControl: RemoteControlStore
    let computerOperator: ComputerOperatorSession
    let permissionPolicy = PermissionPolicy()
    let inferenceProvider: any ModelInferenceProvider
    let termExplanationService: any TermExplanationProviding
    let replySuggestions: ReplySuggestionSession
    let visualAttachments: VisualAttachmentSession
    let voiceLibrary: VoiceLibraryStore
    let voiceCapsules: VoiceCapsuleLibraryStore
    let voiceEngine: VoiceEngineStore
    let voiceCapture: VoiceCaptureSession
    let voiceConversation: VoiceConversationSession
    let sourceContextProvider: any ProjectSourceContextProviding
    let fileEditor: any ProjectFileEditing
    let gitCheckpointProvider: any GitCheckpointing
    let validationProvider: any ProjectValidating
    let simulatorProvider: any SimulatorProviding
    let physicalDeviceProvider: any PhysicalDeviceProviding
    let appleAppLibraryProvider: any AppleAppLibraryProviding
    let xcodeProjectOpener: any XcodeProjectOpening
    let externalReviewHandoff: any ExternalReviewHandoffProviding
    let appleAppScaffolder: any AppleAppScaffolding
    let directorySelector: any DirectorySelectionProviding
    let managedProjectDirectory: any ManagedProjectDirectoryProviding

    private let repository: WorkspaceRepository
    @ObservationIgnored let sourceMonitor = ProjectSourceMonitor()
    @ObservationIgnored private var noticeDismissTask: Task<Void, Never>?
    @ObservationIgnored var inferenceTask: Task<Void, Never>?

    init(
        repository: WorkspaceRepository = WorkspaceRepository(),
        inferenceProvider: any ModelInferenceProvider = BackburnerAwareInferenceProvider(base: LocalInferenceService()),
        sourceContextProvider: any ProjectSourceContextProviding = ProjectSourceContextCollector(),
        fileEditor: any ProjectFileEditing = RecordedProjectFileEditor(),
        gitCheckpointProvider: (any GitCheckpointing)? = nil,
        validationProvider: any ProjectValidating = RecordedProjectValidationService(),
        simulatorProvider: any SimulatorProviding = LocalSimulatorService(),
        physicalDeviceProvider: any PhysicalDeviceProviding = LocalPhysicalDeviceService(
            preparationProvider: RecordedDevicePreparationService()),
        appleAppLibraryProvider: any AppleAppLibraryProviding = LocalAppleAppLibraryService(
            preparationProvider: RecordedDevicePreparationService()),
        xcodeProjectOpener: any XcodeProjectOpening = SystemXcodeProjectOpener(),
        externalReviewHandoff: (any ExternalReviewHandoffProviding)? = nil,
        appleAppScaffolder: any AppleAppScaffolding = AppleAppScaffolder(),
        directorySelector: any DirectorySelectionProviding = SystemDirectorySelectionPanel(),
        managedProjectDirectory: any ManagedProjectDirectoryProviding = ManagedProjectDirectory(),
        voiceTranscriptionProvider: (any VoiceTranscriptionProviding)? = nil,
        voiceConversationTranscriptionProvider: (any VoiceTranscriptionProviding)? = nil,
        voiceResponseSpeaker: (any VoiceResponseSpeaking)? = nil,
        voiceLibrary: VoiceLibraryStore? = nil,
        voiceCapsules: VoiceCapsuleLibraryStore? = nil,
        voiceEngine: VoiceEngineStore? = nil
    ) {
        let detectedRuntimes = ModelRuntimeProbe().detect()
        let loadedLibrary: ProjectLibrary
        let startupNotice: WorkspaceNotice?
        do {
            let loadResult = try repository.loadWorkspace()
            loadedLibrary = loadResult.library ?? .starter
            startupNotice = loadResult.recoveredFromBackup
                ? WorkspaceNotice(
                    message: "ワークスペース本体が壊れていたため、直前のバックアップから復元しました。",
                    kind: .information
                )
                : nil
        } catch {
            loadedLibrary = .starter
            startupNotice = WorkspaceNotice(
                message: "ワークスペースを読み込めませんでした。元ファイルは変更していません：\(error.localizedDescription)",
                kind: .error
            )
        }
        self.repository = repository
        self.inferenceProvider = inferenceProvider
        self.termExplanationService = TermExplanationService(inference: inferenceProvider)
        self.replySuggestions = ReplySuggestionSession(service: ReplySuggestionService(inference: inferenceProvider))
        self.visualAttachments = VisualAttachmentSession()
        let configuredVoiceLibrary = voiceLibrary ?? VoiceLibraryStore()
        self.voiceLibrary = configuredVoiceLibrary
        let configuredVoiceCapsules = voiceCapsules ?? VoiceCapsuleLibraryStore()
        self.voiceCapsules = configuredVoiceCapsules
        let configuredVoiceEngine = voiceEngine ?? VoiceEngineStore()
        self.voiceEngine = configuredVoiceEngine
        self.voiceCapture = VoiceCaptureSession(
            provider: voiceTranscriptionProvider
                ?? VoiceTranscriptionProviderFactory.makeSystemProvider()
        )
        self.voiceConversation = VoiceConversationSession(
            transcriber: voiceConversationTranscriptionProvider
                ?? VoiceTranscriptionProviderFactory.makeSystemProvider(),
            speaker: voiceResponseSpeaker
                ?? VoiceResponseSpeakerFactory.makeSystemSpeaker {
                    configuredVoiceLibrary.selectedProfile
                }
        )
        self.sourceContextProvider = sourceContextProvider
        self.fileEditor = fileEditor
        self.gitCheckpointProvider = gitCheckpointProvider
            ?? GitCheckpointService(fileEditor: fileEditor)
        self.validationProvider = validationProvider
        self.simulatorProvider = simulatorProvider
        self.physicalDeviceProvider = physicalDeviceProvider
        self.appleAppLibraryProvider = appleAppLibraryProvider
        self.xcodeProjectOpener = xcodeProjectOpener
        self.externalReviewHandoff = externalReviewHandoff
            ?? SystemExternalReviewHandoff()
        self.appleAppScaffolder = appleAppScaffolder
        self.directorySelector = directorySelector
        self.managedProjectDirectory = managedProjectDirectory
        self.library = loadedLibrary
        self.runtimes = detectedRuntimes
        self.modelManager = ModelManagerStore(
            runtimes: detectedRuntimes,
            acquisitionCheckpoint: loadedLibrary.modelAcquisitionCheckpoint
        )
        self.remoteControl = RemoteControlStore()
        self.computerOperator = ComputerOperatorSession(
            inferenceProvider: inferenceProvider,
            validationProvider: validationProvider
        )
        self.modelManager.configureCheckpointPersistence { [weak self] checkpoint in
            guard let self else { return }
            guard self.library.modelAcquisitionCheckpoint != checkpoint else { return }
            self.library.modelAcquisitionCheckpoint = checkpoint
            self.persist()
        }
        self.remoteControl.configureInstructionHandler { [weak self] instruction in
            self?.acceptRemoteInstruction(instruction)
                ?? RemoteInstructionDecision(
                    status: .unavailable,
                    message: "Local Factoryのワークスペースを確認できません"
                )
        }
        self.computerOperator.configureResultHandler { [weak self] projectID, result in
            self?.recordComputerOperation(result, projectID: projectID)
        }
        self.computerOperator.configureCheckpointPersistence { [weak self] projectID, checkpoint in
            guard let self else { return }
            guard self.library.records.first(where: { $0.id == projectID })?
                .project.computerOperationCheckpoint != checkpoint else { return }
            self.library.updateProject(projectID) { project in
                project.computerOperationCheckpoint = checkpoint
            }
            self.persist()
        }
        self.voiceCapture.onFinalizedDraft = { [weak self] transcript in
            self?.insertVoiceDraft(transcript)
        }
        self.voiceConversation.onFinalizedTurn = { [weak self] transcript in
            self?.acceptVoiceConversationTurn(transcript)
                ?? .paused(message: "Local Factoryの会話を確認できませんでした")
        }
        if let startupNotice {
            presentNotice(startupNotice.message, kind: startupNotice.kind)
        }
        Task { await configuredVoiceCapsules.refresh() }
        Task { await configuredVoiceEngine.refresh() }
    }

    var project: HarnessProject { library.selectedRecord?.project ?? .starter }

    var hasSelectedProject: Bool { library.selectedRecord != nil }

    var hasConfiguredModel: Bool { project.selectedModel != nil }

    var isGenerating: Bool { generationPhase != .idle }

    var isGeneratingSelectedProject: Bool {
        isGenerating && generationProjectID == library.selectedProjectID
    }

    var appleAppSources: [AppleAppSource] {
        library.activeRecords.compactMap { record in
            guard let rootPath = record.sourceLocation else { return nil }
            return AppleAppSource(
                projectID: record.id,
                projectName: record.project.name,
                rootPath: rootPath
            )
        }
    }

    var generationStatusMessage: String {
        switch generationPhase {
        case .idle: ""
        case .preparingSource: "接続したソースを読み取っています…"
        case .generating: "モデルが回答を作っています…"
        case .revisingResponse: "返答の条件を1回だけ確認し直しています…"
        }
    }

    func isInspectingSource(for id: UUID) -> Bool {
        inspectingSourceProjectIDs.contains(id)
    }

    func sourceChangeSummary(for id: UUID) -> SourceChangeSummary? {
        sourceChangeSummaries[id]
    }

    func persist(successMessage: String? = nil) {
        do {
            try repository.saveLibrary(library)
            if let successMessage {
                presentNotice(successMessage, kind: .success)
            }
        } catch {
            presentNotice("保存できませんでした：\(error.localizedDescription)", kind: .error)
        }
    }

    func dismissNotice() {
        noticeDismissTask?.cancel()
        notice = nil
    }

    func presentNotice(_ message: String, kind: WorkspaceNotice.Kind) {
        noticeDismissTask?.cancel()
        let nextNotice = WorkspaceNotice(message: message, kind: kind)
        notice = nextNotice
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self?.notice?.id == nextNotice.id else { return }
            self?.notice = nil
        }
    }

    private func recordComputerOperation(
        _ result: ComputerOperationResult,
        projectID: UUID
    ) {
        let state = result.wasSkipped ? "スキップ" : (result.succeeded ? "成功" : "失敗")
        let detail: String
        if result.wasSkipped {
            detail = result.message
        } else {
            switch result.step.kind {
            case .projectValidation:
                detail = result.message
            case .webSearch:
                detail = result.message.contains("公開検索結果を")
                    ? "公開検索結果だけを選別して読み取りました"
                    : "確認済みの検索語で既定ブラウザを開きました"
            case .inspectApplication:
                detail = "指定した実行中アプリの画面情報を読み取りました"
            case .pressButton:
                detail = "確認済みの開発用ボタンを1回操作しました"
            }
        }
        library.updateProject(projectID) { project in
            if result.step.kind == .projectValidation,
               result.succeeded,
               !result.wasSkipped {
                project.currentActivity = "Xcodeのビルドとテストに合格しました"
            }
            project.activity.insert(
                ActivityEvent(
                    title: "Computer Operator: \(result.step.kind.displayName) \(state)",
                    detail: detail,
                    kind: result.wasSkipped
                        ? .information
                        : (result.succeeded ? .verification : .warning)
                ),
                at: 0
            )
        }
        persist()
    }
}
