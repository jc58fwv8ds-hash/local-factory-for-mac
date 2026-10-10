import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

struct WorkspaceInteractionPolicyTests {
    @Test func activeWorkBlocksOnlyTheConflictingEntryPoints() {
        let generation = state(isGenerating: true)
        #expect(blocker(.startVoiceConversation, generation) == .modelGeneration)
        #expect(blocker(.submitInstruction, generation) == .modelGeneration)
        #expect(blocker(.prepareComputerOperation, generation) == .modelGeneration)
        #expect(blocker(.changeSelectedProject, generation) == nil)

        let voice = state(isVoiceConversationActive: true)
        #expect(blocker(.submitVoiceTurn, voice) == nil)
        #expect(blocker(.submitInstruction, voice) == .voiceConversation)
        #expect(blocker(.openComputerOperator, voice) == .voiceConversation)
        #expect(blocker(.changeSelectedProject, voice) == .voiceConversation)

        let computer = state(isComputerOperatorBusy: true)
        #expect(blocker(.startVoiceConversation, computer) == .computerOperator)
        #expect(blocker(.submitInstruction, computer) == .computerOperator)
        #expect(blocker(.changeSelectedProject, computer) == .computerOperator)
        #expect(blocker(.openComputerOperator, computer) == nil)
    }

    @Test func pendingCheckpointsCannotBeBypassedByAnotherInputPath() {
        let production = state(hasResumableProjectWork: true)
        for operation in [
            WorkspaceInteractionOperation.startVoiceConversation,
            .submitInstruction,
            .submitVoiceTurn,
            .prepareComputerOperation,
            .executeComputerOperation
        ] {
            #expect(blocker(operation, production) == .resumableProjectWork)
        }

        let computer = state(hasPendingComputerOperation: true)
        #expect(blocker(.startVoiceConversation, computer) == .pendingComputerOperation)
        #expect(blocker(.submitInstruction, computer) == .pendingComputerOperation)
        #expect(blocker(.prepareComputerOperation, computer) == .pendingComputerOperation)
        #expect(blocker(.executeComputerOperation, computer) == nil)
    }

    private func blocker(
        _ operation: WorkspaceInteractionOperation,
        _ state: WorkspaceInteractionState
    ) -> WorkspaceInteractionBlocker? {
        WorkspaceInteractionPolicy.blocker(for: operation, state: state)
    }

    private func state(
        isGenerating: Bool = false,
        isVoiceConversationActive: Bool = false,
        isComputerOperatorBusy: Bool = false,
        hasResumableProjectWork: Bool = false,
        hasPendingComputerOperation: Bool = false
    ) -> WorkspaceInteractionState {
        WorkspaceInteractionState(
            isGenerating: isGenerating,
            isVoiceConversationActive: isVoiceConversationActive,
            isComputerOperatorBusy: isComputerOperatorBusy,
            hasResumableProjectWork: hasResumableProjectWork,
            hasPendingComputerOperation: hasPendingComputerOperation
        )
    }
}

@MainActor
@Suite(.serialized)
struct WorkspaceInteractionIntegrationTests {
    @Test func computerPlanningBlocksNewInstructionsVoiceAndProjectSwitching() async throws {
        let fixture = try InteractionFixture()
        defer { fixture.removeFiles() }
        let store = fixture.store
        let firstID = try #require(store.library.selectedProjectID)

        #expect(store.handoffPrimaryInstructionToComputerOperator("テストして"))
        try await waitUntil { await fixture.provider.requestCount == 1 }
        #expect(store.computerOperator.isBusy)

        let decision = store.acceptRemoteInstruction("そのまま続けて")
        #expect(decision.status == .busy)
        #expect(await fixture.provider.requestCount == 1)
        store.toggleVoiceConversation()
        #expect(!store.voiceConversation.isActive)
        store.selectProject(fixture.secondProjectID)
        #expect(store.library.selectedProjectID == firstID)

        store.computerOperator.stop()
        try await waitUntil { !store.computerOperator.isBusy }
    }

    @Test func activeVoiceBlocksComputerPlanningAndProjectSwitching() throws {
        let fixture = try InteractionFixture()
        defer { fixture.removeFiles() }
        let store = fixture.store
        let firstID = try #require(store.library.selectedProjectID)

        store.toggleVoiceConversation()
        #expect(store.voiceConversation.isActive)
        #expect(!store.handoffPrimaryInstructionToComputerOperator("画面を確認して"))
        #expect(!store.isShowingComputerOperator)
        store.selectProject(fixture.secondProjectID)
        #expect(store.library.selectedProjectID == firstID)
        store.voiceConversation.stop()
    }

    @Test func pendingComputerPlanBlocksRemoteAndVoiceInput() throws {
        let checkpoint = ComputerOperationCheckpoint(
            instruction: "テストして",
            plan: ComputerOperationPlan(
                summary: "テストします",
                steps: [ComputerOperationStep(
                    kind: .projectValidation,
                    reason: "現在の状態を確認します"
                )]
            ),
            nextStepIndex: 0
        )
        let fixture = try InteractionFixture(computerCheckpoint: checkpoint)
        defer { fixture.removeFiles() }
        let before = fixture.store.project

        #expect(fixture.store.acceptRemoteInstruction("続けて").status == .busy)
        fixture.store.toggleVoiceConversation()
        #expect(!fixture.store.voiceConversation.isActive)
        #expect(fixture.store.project == before)
    }

    @Test func staleComputerPlanCannotRunAgainstAnotherProject() async throws {
        let provider = InteractionCompletedPlanInference()
        let session = ComputerOperatorSession(
            inferenceProvider: provider,
            validationProvider: LocalProjectValidationService()
        )
        let first = interactionProject(named: "一つ目")
        let second = interactionProject(named: "二つ目")
        #expect(session.prepareInstruction("テストして", for: first) == .ready)
        session.makePlan(project: first, rootPath: nil)
        try await waitUntil { !session.isBusy }
        #expect(session.plan != nil)

        session.execute(project: second, rootPath: "/別の場所")

        #expect(!session.isBusy)
        #expect(session.nextStepIndex == 0)
        #expect(session.errorMessage?.contains("別のプロジェクト用") == true)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !(await condition()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }

    private func interactionProject(named name: String) -> HarnessProject {
        HarnessProject(
            name: name, summary: "", targets: [.macOS], stage: .build,
            progress: 0.5, currentActivity: "確認中", workItems: [], activity: [],
            selectedModel: ModelSelection(
                identifier: "fixture",
                displayName: "Fixture",
                runtime: .ollama
            )
        )
    }
}

@MainActor
private final class InteractionFixture {
    let directory: URL
    let repository: WorkspaceRepository
    let provider = InteractionHeldInference()
    let secondProjectID: UUID
    let store: WorkspaceStore

    init(computerCheckpoint: ComputerOperationCheckpoint? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Harness-Interaction-\(UUID().uuidString)", isDirectory: true)
        repository = WorkspaceRepository(fileURL: directory.appendingPathComponent("workspace.json"))
        let model = ModelSelection(identifier: "fixture", displayName: "Fixture", runtime: .ollama)
        let first = HarnessProject(
            name: "一つ目", summary: "", targets: [.macOS], stage: .build,
            progress: 0.5, currentActivity: "確認中", workItems: [], activity: [],
            selectedModel: model, computerOperationCheckpoint: computerCheckpoint
        )
        let second = HarnessProject(
            name: "二つ目", summary: "", targets: [.macOS], stage: .build,
            progress: 0.5, currentActivity: "待機中", workItems: [], activity: [],
            selectedModel: model
        )
        secondProjectID = second.id
        try repository.saveLibrary(ProjectLibrary(records: [
            ProjectRecord(project: first),
            ProjectRecord(project: second)
        ]))
        store = WorkspaceStore(
            repository: repository,
            inferenceProvider: provider,
            voiceConversationTranscriptionProvider: ConversationTranscriptionFixture(),
            voiceResponseSpeaker: ConversationSpeakerFixture()
        )
    }

    func removeFiles() { try? FileManager.default.removeItem(at: directory) }
}

private actor InteractionHeldInference: ModelInferenceProvider {
    private(set) var requestCount = 0

    func events(for request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        requestCount += 1
        return AsyncThrowingStream.makeStream().stream
    }
}

private actor InteractionCompletedPlanInference: ModelInferenceProvider {
    func events(for request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                #"{"summary":"テストします","steps":[{"kind":"projectValidation","query":null,"application":null,"element":null,"reason":"確認します"}]}"#
            )
            continuation.finish()
        }
    }
}
