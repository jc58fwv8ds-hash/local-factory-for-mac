import Foundation

@main
struct HarnessCoreChecks {
    static func main() async throws {
        if ProcessInfo.processInfo.environment["HARNESS_PREPARE_VOICE_BENCHMARK_GUI_FIXTURE"] == "1" {
            try VoiceBenchmarkGUIFixture.prepare()
            return
        }
        if ProcessInfo.processInfo.environment["HARNESS_PREPARE_VOICE_CAPSULE_GUI_FIXTURE"] == "1" {
            try VoiceCapsuleGUIFixture.prepare()
            return
        }
        if ProcessInfo.processInfo.environment["HARNESS_PREPARE_REPLAN_GUI_FIXTURE"] == "1" {
            try ReplanGUIFixture.prepare()
            return
        }
        if ProcessInfo.processInfo.environment["HARNESS_PRODUCTION_E2E"] == "1" {
            try await ProductionMultiItemE2EChecks.run()
            return
        }
        if ProcessInfo.processInfo.environment["HARNESS_SINGLE_ITEM_E2E"] == "1" {
            try await ProductionE2EChecks.run()
            return
        }
        if ProcessInfo.processInfo.environment["HARNESS_REPLY_SUGGESTIONS_EVAL"] == "1" {
            try await ReplySuggestionEvaluationChecks.run()
            return
        }
        if ProcessInfo.processInfo.environment["HARNESS_REPLAN_EVAL"] == "1" {
            try await WorkPlanReplanEvaluationChecks.run()
            return
        }
        if ProcessInfo.processInfo.environment["HARNESS_REPLAN_LONG_EVAL"] == "1" {
            try await WorkPlanReplanLongEvaluationChecks.run()
            return
        }
        if ProcessInfo.processInfo.environment["HARNESS_CONVERSATION_EVAL"] == "1" {
            try await ConversationEvaluationChecks.run()
            return
        }
        try await PolicyWorkspaceChecks.run()
        try WorkspaceRecoveryChecks.run()
        try await SourceMonitoringChecks.run()
        try ModelInferenceChecks.run()
        try VisualCommunicationChecks.run()
        try VoiceArchitectureChecks.run()
        try SourceContextSelectionChecks.run()
        try ConversationRephraseChecks.run()
        try ComputerOperationChecks.run()
        try PrimaryInstructionIntentChecks.run()
        try InstructionContinuationChecks.run()
        try await TermExplanationChecks.run()
        try ModelHostResourceChecks.run()
        try RemoteInstructionChecks.run()
        try AppleAppScaffoldingChecks.run()
        try await ModelAcquisitionChecks.run()
        try WorkPlanChecks.run()
        try await FileEditingChecks.run()
        try await ProjectValidationChecks.run()
        try BuildFailureAnalysisChecks.run()
        try RepairResumeChecks.run()
        try ProjectOperationCheckpointChecks.run()
        try CreationLoopChecks.run()
        try RunCoordinatorChecks.run()
        try ArtifactCreationPlanChecks.run()
        try await XcodeValidationChecks.run()
        try SimulatorChecks.run()
        try PhysicalDeviceChecks.run()
        try AppleAppLibraryChecks.run()
        if ProcessInfo.processInfo.environment["HARNESS_SIMULATOR_INTEGRATION"] == "1" {
            try await SimulatorIntegrationChecks.run()
        }
        if ProcessInfo.processInfo.environment["HARNESS_DEVICE_INTEGRATION"] == "1" {
            try await PhysicalDeviceIntegrationChecks.run()
        }
        if let rootPath = ProcessInfo.processInfo.environment["HARNESS_APP_LIBRARY_ROOT"] {
            try await AppleAppLibraryIntegrationChecks.run(rootPath: rootPath)
        }
        print("All HarnessCore checks passed.")
    }
}
