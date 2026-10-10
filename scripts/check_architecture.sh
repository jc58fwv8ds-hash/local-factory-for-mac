#!/bin/zsh

set -euo pipefail

readonly max_swift_lines=350
integer failure_count=0

# Compile-time target dependencies and import allowlists keep the new kernel headless.
for kernel_target in HarnessKernelContracts HarnessKernel HarnessKernelPersistence HarnessExecution; do
    case "$kernel_target" in
        HarnessKernelContracts) allowed_imports='^import Foundation$' ;;
        HarnessKernel) allowed_imports='^import (Foundation|HarnessKernelContracts)$' ;;
        HarnessKernelPersistence) allowed_imports='^import (Foundation|Darwin|HarnessKernelContracts)$' ;;
        HarnessExecution) allowed_imports='^import (Foundation|CryptoKit|HarnessCore|HarnessKernel|HarnessKernelContracts|HarnessKernelPersistence)$' ;;
    esac
    unexpected_imports=$(rg --no-filename '^(@[^ ]+ )?import ' "Sources/$kernel_target" \
        | rg -v "$allowed_imports" || true)
    if [[ -n "$unexpected_imports" ]]; then
        print -u2 "Architecture: $kernel_target imports outside its boundary: $unexpected_imports"
        (( failure_count += 1 ))
    fi
done

if rg -n '\b(Process|URLSession)\b' Sources/HarnessExecution >/dev/null; then
    print -u2 "Architecture: execution orchestration must use runtime adapters, not direct processes or transport."
    (( failure_count += 1 ))
fi

if rg -n '\b(Process|FileManager|FileHandle|URLSession|UserDefaults)\b' \
    Sources/HarnessKernel Sources/HarnessKernelContracts >/dev/null; then
    print -u2 "Architecture: kernel and contracts must not perform direct I/O."
    (( failure_count += 1 ))
fi

while IFS= read -r source_file; do
    integer line_count
    line_count=$(wc -l < "$source_file")
    if (( line_count > max_swift_lines )); then
        print -u2 "Architecture: $source_file is $line_count lines (limit: $max_swift_lines)."
        (( failure_count += 1 ))
    fi
done < <(find Sources -name '*.swift' -type f | sort)

if rg -n '^import (SwiftUI|AppKit)$' Sources/HarnessCore >/dev/null; then
    print -u2 "Architecture: HarnessCore must not depend on SwiftUI or AppKit."
    rg -n '^import (SwiftUI|AppKit)$' Sources/HarnessCore >&2
    (( failure_count += 1 ))
fi

if rg -n '\b(URLSession|Process|FileManager\.default)\b' Sources/HarnessApp/Views >/dev/null; then
    print -u2 "Architecture: Views must not perform transport, process, or filesystem work directly."
    rg -n '\b(URLSession|Process|FileManager\.default)\b' Sources/HarnessApp/Views >&2
    (( failure_count += 1 ))
fi

if rg -n '\.font\(\.(title|title2|title3|headline|body|subheadline|caption|caption2)' Sources/HarnessApp/Views >/dev/null; then
    print -u2 "Architecture: Views must use HarnessTypography semantic tokens."
    rg -n '\.font\(\.(title|title2|title3|headline|body|subheadline|caption|caption2)' Sources/HarnessApp/Views >&2
    (( failure_count += 1 ))
fi

raw_system_fonts=$(rg -n '\.font\(\.system' Sources/HarnessApp/Views \
    | rg -v 'design: \.monospaced' || true)
if [[ -n "$raw_system_fonts" ]]; then
    print -u2 "Architecture: non-code fonts must come from HarnessTypography."
    print -u2 "$raw_system_fonts"
    (( failure_count += 1 ))
fi

if rg -n '\.accessibilityIdentifier\("' Sources/HarnessApp/Views >/dev/null; then
    print -u2 "Architecture: accessibility IDs must come from HarnessAccessibilityID."
    rg -n '\.accessibilityIdentifier\("' Sources/HarnessApp/Views >&2
    (( failure_count += 1 ))
fi

duplicate_accessibility_ids=$(rg -o '"harness\.[^"]+"' \
    Sources/HarnessApp/HarnessAccessibility.swift | sort | uniq -d || true)
if [[ -n "${duplicate_accessibility_ids}" ]]; then
    print -u2 "Architecture: duplicate accessibility IDs found."
    print -u2 "${duplicate_accessibility_ids}"
    (( failure_count += 1 ))
fi

readonly inference_boundaries=(
    Sources/HarnessCore/InferenceOutputBudget.swift
    Sources/HarnessCore/InferencePromptComposition.swift
    Sources/HarnessCore/InferenceResponseTiming.swift
    Sources/HarnessCore/NaturalLanguageExplanationGuidance.swift
    Sources/HarnessCore/InferenceStructuredOutput.swift
    Sources/HarnessCore/InferenceStreamParser.swift
    Sources/HarnessCore/LocalInferenceSessionPolicy.swift
    Sources/HarnessCore/LocalInferenceService.swift
    Sources/HarnessCore/ProjectPromptBuilder.swift
    Sources/HarnessCore/ConversationPromptHistory.swift
    Sources/HarnessCore/ConversationResponseText.swift
    Sources/HarnessCore/ConversationResponseIdentity.swift
    Sources/HarnessCore/ConversationRephrasePolicy.swift
    Sources/HarnessCore/ConversationSentenceCountPolicy.swift
    Sources/HarnessCore/ConversationResponseGuard.swift
    Sources/HarnessCore/ConversationClarifyingContext.swift
    Sources/HarnessCore/PromptReferenceText.swift
    Sources/HarnessCore/SourceReferencePromptBuilder.swift
    Sources/HarnessCore/SourceContextSelectionPolicy.swift
    Sources/HarnessCore/ProjectInferenceWorkflow.swift
    Sources/HarnessCore/ProjectFileEditInferenceWorkflow.swift
    Sources/HarnessCore/ExternalReviewPromptBoundary.swift
    Sources/HarnessCore/ArtifactPlanInference.swift
    Sources/HarnessCore/ArtifactCreationPlanWorkflow.swift
    Sources/HarnessCore/ComputerOperationCheckpoint.swift
    Sources/HarnessCore/ComputerOperationPlan.swift
    Sources/HarnessCore/ComputerOperationPolicy.swift
    Sources/HarnessCore/ComputerOperationResultSummary.swift
    Sources/HarnessCore/PublicWebSearchResult.swift
    Sources/HarnessCore/PrimaryInstructionIntent.swift
    Sources/HarnessCore/ContinuationInstruction.swift
    Sources/HarnessCore/ProjectInstructionContext.swift
    Sources/HarnessCore/ProjectInstructionAcceptance.swift
    Sources/HarnessCore/ResponseTerm.swift
    Sources/HarnessCore/TermExplanationService.swift
    Sources/HarnessCore/ReplySuggestion.swift
    Sources/HarnessCore/ReplySuggestionContext.swift
    Sources/HarnessCore/ReplySuggestionService.swift
    Sources/HarnessCore/ReplySuggestionsSchema.swift
    Sources/HarnessCore/WorkPlanReplanInference.swift
    Sources/HarnessCore/WorkspaceInteractionPolicy.swift
)

readonly model_boundaries=(
    Sources/HarnessCore/ModelHostResources.swift
    Sources/HarnessCore/ModelAcquisition.swift
    Sources/HarnessCore/ModelAcquisitionProgress.swift
    Sources/HarnessCore/ModelCommandFailureExplainer.swift
    Sources/HarnessCore/ModelCapabilityParser.swift
    Sources/HarnessCore/LocalModelService.swift
    Sources/HarnessApp/ModelManagerStore.swift
    Sources/HarnessApp/ModelManagerStore+Compatibility.swift
    Sources/HarnessApp/Views/ModelAcquisitionResumeNotice.swift
    Sources/HarnessApp/Views/ModelOperationBanner.swift
)

readonly visual_boundaries=(
    Sources/HarnessCore/VisualAssetTypes.swift
    Sources/HarnessCore/VisualAnalysisPolicy.swift
    Sources/HarnessCore/VisualActionAuthorityPolicy.swift
    Sources/HarnessCore/VisualAttachmentPolicy.swift
    Sources/HarnessCore/VisualContentHash.swift
    Sources/HarnessCore/VisualEditPolicy.swift
    Sources/HarnessCore/VisualModelRoutingPolicy.swift
    Sources/HarnessCore/VisualReferenceBoundary.swift
    Sources/HarnessCore/InferencePayloadEncoding.swift
    Sources/HarnessApp/VisualAttachmentImporter.swift
    Sources/HarnessApp/VisualPasteboardProvider.swift
    Sources/HarnessApp/VisualAttachmentSession.swift
    Sources/HarnessApp/WorkspaceStore+VisualAttachments.swift
    Sources/HarnessApp/Views/VisualAttachmentStrip.swift
)

readonly voice_boundaries=(
    Sources/HarnessCore/VoiceInteractionTypes.swift
    Sources/HarnessCore/VoiceTranscriptFeedback.swift
    Sources/HarnessCore/VoiceActionAuthorityPolicy.swift
    Sources/HarnessCore/VoiceCapsuleTypes.swift
    Sources/HarnessCore/VoiceCapsulePolicy.swift
    Sources/HarnessCore/VoiceCapsuleTranscriptPolicy.swift
    Sources/HarnessCore/VoiceEngineTypes.swift
    Sources/HarnessCore/VoiceEngineInstallation.swift
    Sources/HarnessCore/VoiceEngineBenchmark.swift
    Sources/HarnessCore/VoiceEngineOperationPolicy.swift
    Sources/HarnessCore/VoiceDraftComposition.swift
    Sources/HarnessCore/VoiceConversationPolicy.swift
    Sources/HarnessCore/VoiceConversationMetrics.swift
    Sources/HarnessCore/VoiceModelLibrary.swift
    Sources/HarnessCore/VoiceTurnTakingPolicy.swift
    Sources/HarnessApp/VoiceTranscriptionProvider.swift
    Sources/HarnessApp/VoiceMicrophonePermission.swift
    Sources/HarnessApp/VoiceCaptureSession.swift
    Sources/HarnessApp/VoiceConversationSession.swift
    Sources/HarnessApp/VoiceConversationSubmission.swift
    Sources/HarnessApp/VoiceConversationTiming.swift
    Sources/HarnessApp/VoiceResponseSpeaker.swift
    Sources/HarnessApp/AppleVoiceResponseSpeaker.swift
    Sources/HarnessApp/AppleVoiceSpeechRenderer.swift
    Sources/HarnessApp/SystemVoiceCatalog.swift
    Sources/HarnessApp/VoiceLibraryStore.swift
    Sources/HarnessApp/VoicePreviewSession.swift
    Sources/HarnessApp/VoiceSampleImporter.swift
    Sources/HarnessApp/VoiceCapsuleAssetStore.swift
    Sources/HarnessApp/VoiceCapsuleLibraryStore.swift
    Sources/HarnessApp/VoiceCapsuleEngineInput.swift
    Sources/HarnessApp/Qwen3TTSMLXConfiguration.swift
    Sources/HarnessApp/Qwen3TTSMLXAdapter.swift
    Sources/HarnessApp/Qwen3TTSMLXInstaller.swift
    Sources/HarnessApp/Qwen3TTSMLXInstaller+Validation.swift
    Sources/HarnessApp/VoiceEngineInstallerSupport.swift
    Sources/HarnessApp/VoiceEngineStore.swift
    Sources/HarnessApp/VoiceEngineBenchmarkSession.swift
    Sources/HarnessApp/AppleSpeechAudioConverter.swift
    Sources/HarnessApp/AppleSpeechAudioActivityDetector.swift
    Sources/HarnessApp/AppleSpeechAudioInputBridge.swift
    Sources/HarnessApp/AppleSpeechTranscriptionProvider.swift
    Sources/HarnessApp/WorkspaceStore+VoiceInput.swift
    Sources/HarnessApp/WorkspaceStore+VoiceLibrary.swift
    Sources/HarnessApp/Views/VoiceInputControl.swift
    Sources/HarnessApp/Views/VoiceLibraryView.swift
    Sources/HarnessApp/Views/VoiceLibraryComponents.swift
    Sources/HarnessApp/Views/VoiceCapsuleComponents.swift
    Sources/HarnessApp/Views/VoiceCapsuleCreationView.swift
    Sources/HarnessApp/Views/VoiceCapsuleTranscriptView.swift
    Sources/HarnessApp/Views/VoiceEngineStatusCard.swift
    Sources/HarnessApp/Views/VoiceEngineBenchmarkCard.swift
)

readonly app_boundaries=(
    Sources/HarnessApp/ConversationPerformance.swift
    Sources/HarnessApp/Views/ConversationPerformanceView.swift
    Sources/HarnessApp/ReplySuggestionSession.swift
    Sources/HarnessApp/WorkPlanReplanSession.swift
    Sources/HarnessApp/WorkspaceStore+ReplySuggestions.swift
    Sources/HarnessApp/Views/WorkPlanReplanView.swift
    Sources/HarnessApp/Views/ValidationFailureClassificationView.swift
    Sources/HarnessApp/Views/ReplySuggestionsView.swift
    Sources/HarnessApp/Views/CommandComposer.swift
    Sources/HarnessApp/Views/CreationLoopCard.swift
    Sources/HarnessApp/WorkspaceStore+RunCoordinator.swift
    Sources/HarnessApp/Views/RunCoordinatorCard.swift
    Sources/HarnessApp/HarnessApplicationDelegate.swift
    Sources/HarnessApp/HarnessAppEnvironment.swift
    Sources/HarnessApp/HarnessAccessibility.swift
    Sources/HarnessApp/HarnessTypography.swift
    Sources/HarnessApp/FileChangeSession.swift
    Sources/HarnessApp/ArtifactPlanSession.swift
    Sources/HarnessApp/ProjectValidationSession.swift
    Sources/HarnessApp/SimulatorSession.swift
    Sources/HarnessApp/PhysicalDeviceSession.swift
    Sources/HarnessApp/AppleAppLibrarySession.swift
    Sources/HarnessApp/XcodeProjectOpener.swift
    Sources/HarnessApp/Views/SourceChangeNotice.swift
    Sources/HarnessApp/Views/ExistingProjectAppStarterView.swift
    Sources/HarnessApp/ActivityInspectorContexts.swift
    Sources/HarnessApp/Views/ActivityInspectorPresentation.swift
    Sources/HarnessApp/Views/PhysicalDeviceView.swift
    Sources/HarnessApp/Views/AppleAppLibraryView.swift
    Sources/HarnessApp/Views/AppleAppTile.swift
    Sources/HarnessApp/Views/AppleAppInstallPanel.swift
    Sources/HarnessApp/Views/FileChangeFileList.swift
    Sources/HarnessApp/Views/FileRepairPlanPanel.swift
    Sources/HarnessApp/Views/RepairResumeNotice.swift
    Sources/HarnessApp/Views/ValidationResumeNotice.swift
    Sources/HarnessApp/Views/InferenceResumeNotice.swift
    Sources/HarnessApp/Views/FileEditInferenceResumeNotice.swift
    Sources/HarnessApp/Views/ArtifactPlanningResumeNotice.swift
    Sources/HarnessApp/Views/ArtifactCreationPlanResumeNotice.swift
    Sources/HarnessApp/Views/ArtifactPlanComposer.swift
    Sources/HarnessApp/Views/ArtifactCreationPlanPanel.swift
    Sources/HarnessApp/ExternalReviewHandoff.swift
    Sources/HarnessApp/ExternalReviewSession.swift
    Sources/HarnessApp/WorkspaceStore+CreationLoop.swift
    Sources/HarnessApp/Views/ExternalReviewView.swift
    Sources/HarnessApp/Views/ValidationRevisionGuidanceView.swift
    Sources/HarnessApp/ComputerOperatorSession.swift
    Sources/HarnessApp/ComputerOperatorSession+Execution.swift
    Sources/HarnessApp/MacComputerController.swift
    Sources/HarnessApp/Views/ComputerOperatorView.swift
    Sources/HarnessApp/WorkspaceStore+ComputerOperator.swift
    Sources/HarnessApp/WorkspaceStore+InstructionSubmission.swift
    Sources/HarnessApp/WorkspaceStore+InteractionPolicy.swift
    Sources/HarnessApp/ResponseTextView.swift
    Sources/HarnessApp/TermExplanationPresenter.swift
    Sources/HarnessApp/TermExplanationSession.swift
    Sources/HarnessApp/Views/ExplainedResponseText.swift
    Sources/HarnessApp/Views/TermExplanationPopover.swift
)

readonly remote_boundaries=(
    Sources/HarnessCore/RemoteInstruction.swift
    Sources/HarnessCore/RemoteInvitationPolicy.swift
    Sources/HarnessApp/RemotePeerTransport.swift
    Sources/HarnessApp/RemoteControlStore.swift
    Sources/HarnessApp/Views/RemoteControlCard.swift
    Sources/HarnessApp/WorkspaceStore+Scaffolding.swift
    Sources/HarnessApp/DirectorySelectionPanel.swift
)

readonly scaffolding_boundaries=(
    Sources/HarnessCore/ManagedProjectDirectory.swift
    Sources/HarnessCore/AppleAppScaffolding.swift
    Sources/HarnessCore/AppleAppStarterFiles.swift
    Sources/HarnessCore/AppleAppProjectTemplate.swift
)

readonly accessibility_contract=(
    root
    sidebarHome
    sidebarProjects
    sidebarApps
    sidebarModels
    sidebarVoices
    sidebarNewProject
    sidebarAppearance
    sidebarModelManager
    projectLibrary
    projectSearch
    projectImport
    projectCreate
    projectFormName
    projectFormSummary
    modelManager
    modelRefresh
    modelDone
    modelRuntime
    modelResources
    voiceLibrary
    voiceAdd
    voiceDone
    voiceCapsuleTranscriptAdd
    voiceCapsuleTranscriptAddField
    voiceCapsuleTranscriptAddSave
    voiceEngineStatus
    voiceEngineRefresh
    voiceEngineInstall
    voiceEngineStop
    voiceEngineResume
    voiceEngineDiscard
    voiceEngineRemove
    remoteControlToggle
    remotePairingCode
    commandField
    commandSubmit
    commandImageAdd
    commandVoicePushToTalk
    commandVoiceCancel
    commandVoiceConversation
    commandVoiceConversationStop
    voiceProfile
    replySuggestionsGenerate
    replySuggestionsCancel
    replySuggestion
    responseText
    responsePerformance
    termExplanation
    sourceEdit
    sourceNewFile
    sourceArtifactPlan
    sourceValidate
    projectValidationRun
    physicalDeviceOpen
    physicalDeviceOpenXcode
    physicalDeviceRefresh
    physicalDeviceRun
    appLibrary
    appLibraryRefresh
    appLibraryInstall
    creationLoopMode
    creationLoopComplete
    runCoordinatorPrimary
    runCoordinatorPause
    workPlanReplanGenerate
    workPlanReplanStop
    workPlanReplanDiscard
    workPlanReplanAdopt
    externalReview
    externalReviewOpen
    externalReviewResponse
    externalReviewImport
    newProjectSheet
    newProjectCreate
    newProjectIPhoneTemplate
)

readonly validation_boundaries=(
    Sources/HarnessCore/BoundedCommandRunner.swift
    Sources/HarnessCore/ValidationCommandRunner.swift
    Sources/HarnessCore/LocalProjectValidationService.swift
    Sources/HarnessCore/SwiftPackageValidationService.swift
    Sources/HarnessCore/XcodeProjectValidationService.swift
    Sources/HarnessCore/XcodeProjectLocator.swift
    Sources/HarnessCore/XcodeProjectSelection.swift
    Sources/HarnessCore/XcodeToolchainLocator.swift
    Sources/HarnessCore/XcodeCommandEnvironmentResolver.swift
    Sources/HarnessCore/SimulatorTypes.swift
    Sources/HarnessCore/SimulatorDeviceParser.swift
    Sources/HarnessCore/LocalSimulatorService.swift
    Sources/HarnessCore/PhysicalDeviceTypes.swift
    Sources/HarnessCore/PhysicalDeviceParser.swift
    Sources/HarnessCore/PhysicalDeviceReadinessEvaluator.swift
    Sources/HarnessCore/PhysicalDeviceServiceError.swift
    Sources/HarnessCore/XcodeSigningSettingsParser.swift
    Sources/HarnessCore/LocalPhysicalDeviceService.swift
    Sources/HarnessCore/AppleAppLibraryTypes.swift
    Sources/HarnessCore/AppleAppBuildSettingsParser.swift
    Sources/HarnessCore/AppleAppIconLoader.swift
    Sources/HarnessCore/AppleAppInstallSelectionPolicy.swift
    Sources/HarnessCore/AppleAppLibraryError.swift
    Sources/HarnessCore/LocalAppleDeviceInventoryService.swift
    Sources/HarnessCore/LocalAppleAppCatalog.swift
    Sources/HarnessCore/LocalAppleAppInstaller.swift
    Sources/HarnessCore/LocalAppleAppLibraryService.swift
    Sources/HarnessCore/ProjectSourceMonitor.swift
    Sources/HarnessCore/BuildFailureAnalyzer.swift
    Sources/HarnessCore/BuildRepairPlan.swift
    Sources/HarnessCore/RepairResumeState.swift
    Sources/HarnessCore/ProjectOperationCheckpoint.swift
    Sources/HarnessCore/CreationLoop.swift
    Sources/HarnessCore/RunCoordinatorTypes.swift
    Sources/HarnessCore/RunCoordinator.swift
    Sources/HarnessCore/RunCoordinatorRecovery.swift
    Sources/HarnessCore/CreationCompletionPolicy.swift
    Sources/HarnessCore/ProjectMilestoneProgress.swift
    Sources/HarnessCore/ExternalReviewPacket.swift
    Sources/HarnessCore/ValidationRevisionGuidance.swift
    Sources/HarnessCore/ValidationFailureClassification.swift
    Sources/HarnessCore/WorkPlanReplanTypes.swift
    Sources/HarnessCore/WorkPlanReplanContext.swift
    Sources/HarnessCore/WorkPlanReplanWorkflow.swift
)

readonly persistence_boundaries=(
    Sources/HarnessCore/WorkspaceRecovery.swift
    Sources/HarnessCore/WorkspaceRepository.swift
)

readonly release_boundaries=(
    Packaging/Harness-Info.plist
    scripts/build_app_icon.sh
    scripts/package_release.sh
)

readonly evaluation_boundaries=(
    Sources/HarnessCoreChecks/ProductionE2EChecks.swift
    Sources/HarnessCoreChecks/ProductionE2EEngine.swift
    Sources/HarnessCoreChecks/ProductionMultiItemE2EChecks.swift
    Sources/HarnessCoreChecks/ProductionMultiItemFixture.swift
    Sources/HarnessCoreChecks/WorkPlanReplanEvaluationChecks.swift
    Sources/HarnessCoreChecks/WorkPlanReplanEvaluationEngine.swift
    Sources/HarnessCoreChecks/WorkPlanReplanLongEvaluationChecks.swift
    Sources/HarnessCoreChecks/ReplanGUIFixture.swift
    Sources/HarnessCoreChecks/VoiceCapsuleGUIFixture.swift
    Sources/HarnessCoreChecks/VoiceBenchmarkGUIFixture.swift
)

for boundary in $inference_boundaries; do
    if [[ ! -f "$boundary" ]]; then
        print -u2 "Architecture: missing inference boundary $boundary."
        (( failure_count += 1 ))
    fi
done

for boundary in $model_boundaries; do
    if [[ ! -f "$boundary" ]]; then
        print -u2 "Architecture: missing model boundary $boundary."
        (( failure_count += 1 ))
    fi
done

for boundary in $visual_boundaries; do
    if [[ ! -f "$boundary" ]]; then
        print -u2 "Architecture: missing visual communication boundary $boundary."
        (( failure_count += 1 ))
    fi
done

for boundary in $voice_boundaries; do
    if [[ ! -f "$boundary" ]]; then
        print -u2 "Architecture: missing voice boundary $boundary."
        (( failure_count += 1 ))
    fi
done

for boundary in $app_boundaries; do
    if [[ ! -f "$boundary" ]]; then
        print -u2 "Architecture: missing app boundary $boundary."
        (( failure_count += 1 ))
    fi
done

for boundary in $remote_boundaries; do
    if [[ ! -f "$boundary" ]]; then
        print -u2 "Architecture: missing remote boundary $boundary."
        (( failure_count += 1 ))
    fi
done

for boundary in $scaffolding_boundaries; do
    if [[ ! -f "$boundary" ]]; then
        print -u2 "Architecture: missing scaffolding boundary $boundary."
        (( failure_count += 1 ))
    fi
done

for identifier in $accessibility_contract; do
    if ! rg -F "HarnessAccessibilityID.${identifier}" Sources/HarnessApp/Views >/dev/null; then
        print -u2 "Architecture: missing accessibility contract ${identifier}."
        (( failure_count += 1 ))
    fi
done

for boundary in $validation_boundaries; do
    if [[ ! -f "$boundary" ]]; then
        print -u2 "Architecture: missing validation boundary $boundary."
        (( failure_count += 1 ))
    fi
done

for boundary in $persistence_boundaries; do
    if [[ ! -f "$boundary" ]]; then
        print -u2 "Architecture: missing persistence boundary $boundary."
        (( failure_count += 1 ))
    fi
done

for boundary in $release_boundaries; do
    if [[ ! -f "$boundary" ]]; then
        print -u2 "Architecture: missing release boundary $boundary."
        (( failure_count += 1 ))
    fi
done

for boundary in $evaluation_boundaries; do
    if [[ ! -f "$boundary" ]]; then
        print -u2 "Architecture: missing evaluation boundary $boundary."
        (( failure_count += 1 ))
    fi
done

if (( failure_count > 0 )); then
    print -u2 "Architecture checks failed: $failure_count issue(s)."
    exit 1
fi

print "Architecture checks passed."
