import Foundation

enum HarnessAccessibilityID {
    static let root = "harness.root"
    static let sidebarHome = "harness.sidebar.home"
    static let sidebarProjects = "harness.sidebar.projects"
    static let sidebarApps = "harness.sidebar.apps"
    static let sidebarModels = "harness.sidebar.models"
    static let sidebarVoices = "harness.sidebar.voices"
    static let sidebarNewProject = "harness.sidebar.new-project"
    static let sidebarAppearance = "harness.sidebar.appearance"
    static let sidebarModelManager = "harness.sidebar.model-manager"

    static let projectLibrary = "harness.projects.library"
    static let projectSearch = "harness.projects.search"
    static let projectImport = "harness.projects.import"
    static let projectCreate = "harness.projects.create"
    static let projectFormName = "harness.project-form.name"
    static let projectFormSummary = "harness.project-form.summary"
    static let newProjectSheet = "harness.new-project.sheet"
    static let newProjectCreate = "harness.new-project.create"
    static let newProjectIPhoneTemplate = "harness.new-project.iphone-template"

    static let modelManager = "harness.models.manager"
    static let modelRefresh = "harness.models.refresh"
    static let modelDone = "harness.models.done"
    static let modelRuntime = "harness.models.runtime"
    static let modelResources = "harness.models.resources"
    static let voiceLibrary = "harness.voices.library"
    static let voiceAdd = "harness.voices.add"
    static let voiceDone = "harness.voices.done"
    static let voiceCapsuleCreator = "harness.voices.capsule.creator"
    static let voiceCapsuleChooseMP3 = "harness.voices.capsule.choose-mp3"
    static let voiceCapsuleName = "harness.voices.capsule.name"
    static let voiceCapsuleTranscript = "harness.voices.capsule.transcript"
    static let voiceCapsuleConsent = "harness.voices.capsule.consent"
    static let voiceCapsuleCreate = "harness.voices.capsule.create"
    static let voiceCapsuleTranscriptAdd = "harness.voices.capsule.transcript-add"
    static let voiceCapsuleTranscriptAddField = "harness.voices.capsule.transcript-add-field"
    static let voiceCapsuleTranscriptAddSave = "harness.voices.capsule.transcript-add-save"
    static let voiceEngineStatus = "harness.voices.engine.status"
    static let voiceEngineRefresh = "harness.voices.engine.refresh"
    static let voiceEngineInstall = "harness.voices.engine.install"
    static let voiceEngineStop = "harness.voices.engine.stop"
    static let voiceEngineResume = "harness.voices.engine.resume"
    static let voiceEngineDiscard = "harness.voices.engine.discard"
    static let voiceEngineRemove = "harness.voices.engine.remove"
    static let voiceEngineBenchmarkRun = "harness.voices.engine.benchmark.run"
    static let voiceEngineBenchmarkStop = "harness.voices.engine.benchmark.stop"
    static let remoteControlToggle = "harness.remote.enabled"
    static let remotePairingCode = "harness.remote.pairing-code"

    static let commandField = "harness.command.field"
    static let commandSubmit = "harness.command.submit"
    static let commandImageAdd = "harness.command.image-add"
    static let commandVoicePushToTalk = "harness.command.voice-push-to-talk"
    static let commandVoiceCancel = "harness.command.voice-cancel"
    static let commandVoiceConversation = "harness.command.voice-conversation"
    static let commandVoiceConversationStop = "harness.command.voice-conversation-stop"
    static let responseText = "harness.response.text"
    static let responsePerformance = "harness.response.performance"
    static let termExplanation = "harness.response.term-explanation"
    static let replySuggestionsGenerate = "harness.reply-suggestions.generate"
    static let replySuggestionsCancel = "harness.reply-suggestions.cancel"
    static let computerOperatorOpen = "harness.computer.open"
    static let computerOperatorInstruction = "harness.computer.instruction"
    static let computerOperatorPlan = "harness.computer.plan"
    static let computerOperatorRun = "harness.computer.run"
    static let sourceEdit = "harness.source.edit"
    static let sourceCreateIPhoneApp = "harness.source.create-iphone-app"
    static let sourceNewFile = "harness.source.new-file"
    static let sourceArtifactPlan = "harness.source.artifact-plan"
    static let sourceValidate = "harness.source.validate"
    static let projectValidationRun = "harness.validation.run"
    static let physicalDeviceOpen = "harness.device.open"
    static let physicalDeviceOpenXcode = "harness.device.open-xcode"
    static let physicalDeviceRefresh = "harness.device.refresh"
    static let physicalDeviceRun = "harness.device.run"
    static let appLibrary = "harness.apps.library"
    static let appLibraryRefresh = "harness.apps.refresh"
    static let appLibraryInstall = "harness.apps.install"
    static let creationLoopMode = "harness.creation-loop.mode"
    static let creationLoopComplete = "harness.creation-loop.complete"
    static let runCoordinatorPrimary = "harness.run-coordinator.primary"
    static let runCoordinatorPause = "harness.run-coordinator.pause"
    static let workPlanReplanGenerate = "harness.work-plan-replan.generate"
    static let workPlanReplanStop = "harness.work-plan-replan.stop"
    static let workPlanReplanDiscard = "harness.work-plan-replan.discard"
    static let workPlanReplanAdopt = "harness.work-plan-replan.adopt"
    static let externalReview = "harness.external-review"
    static let externalReviewOpen = "harness.external-review.open"
    static let externalReviewResponse = "harness.external-review.response"
    static let externalReviewImport = "harness.external-review.import"

    static func sidebarProject(_ id: UUID) -> String {
        "harness.sidebar.project.\(id.uuidString.lowercased())"
    }

    static func appTile(_ id: String) -> String {
        "harness.apps.tile.\(id.lowercased())"
    }

    static func replySuggestion(_ id: UUID) -> String {
        "harness.reply-suggestions.choice.\(id.uuidString.lowercased())"
    }

    static func commandImageRemove(_ id: UUID) -> String {
        "harness.command.image-remove.\(id.uuidString.lowercased())"
    }

    static func voiceProfile(_ id: String) -> String {
        "harness.voices.profile.\(id.lowercased())"
    }

    static func voiceCapsule(_ id: UUID) -> String {
        "harness.voices.capsule.\(id.uuidString.lowercased())"
    }
}
