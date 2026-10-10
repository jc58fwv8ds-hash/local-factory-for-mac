import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

@MainActor
@Suite(.serialized)
struct InstructionSubmissionTests {
    @Test func macAndRemoteContinuationsUseTheReturnedResponseID() async throws {
        let fixture = try SubmissionFixture()
        defer { fixture.removeFiles() }
        let store = fixture.store
        let productionItems = store.project.workItems
        store.instruction = "端末間の役割を考えてね"
        store.submitInstruction()
        await store.inferenceTask?.value
        let responseID = try #require(store.project.workItems.first?.id)

        store.instruction = "続けてちょ"
        store.submitInstruction()
        #expect(store.instruction.isEmpty)
        #expect(store.project.operationCheckpoint?.referenceID == responseID)
        await store.inferenceTask?.value
        let decision = store.acceptRemoteInstruction("続けよ")
        #expect(decision.status == .accepted)
        #expect(store.project.operationCheckpoint?.referenceID == responseID)
        await store.inferenceTask?.value

        #expect(store.project.workItems.count == productionItems.count + 1)
        #expect(store.project.workItems.first?.status == .completed)
        #expect(store.project.workItems.filter { $0.id != responseID } == productionItems)
        #expect(store.project.operationCheckpoint == nil)
        #expect(store.project.conversation.filter { $0.role == .user }.map(\.content)
            == ["端末間の役割を考えてね", "続けてちょ", "続けよ"])
        #expect(store.project.conversation.filter { $0.role == .user }.last?.origin == .remoteUser)
        let requests = await fixture.provider.requests
        #expect(requests.count == 3)
        let timing = try #require(store.visibleConversationPerformance)
        #expect(timing.attempts.count == 1 && timing.responseID == store.project.conversation.last?.id)
        #expect(timing.attempts[0].promptCharacters == requests[2].messages.reduce(0) { $0 + $1.content.count })
        let reloaded = WorkspaceStore(repository: fixture.repository, inferenceProvider: fixture.provider)
        #expect(reloaded.lastConversationPerformance == nil)
        #expect(requests.last?.messages.first?.content.contains("次の候補: 端末間の役割を設計") == true)
        #expect(try fixture.repository.loadLibrary()?.selectedRecord?.project == store.project)
    }

    @Test func noModelQueuesOneResponseRecordWithoutLosingWords() throws {
        let fixture = try SubmissionFixture(hasModel: false)
        defer { fixture.removeFiles() }
        let store = fixture.store
        let initialCount = store.project.workItems.count
        for phrase in ["続けて", "再開"] {
            store.instruction = phrase
            store.submitInstruction()
            #expect(store.instruction.isEmpty)
        }
        #expect(store.project.workItems.count == initialCount + 1)
        #expect(store.project.workItems.first?.status == .needsAttention)
        #expect(!store.isGenerating)
        #expect(store.project.conversation.map(\.content) == ["続けて", "再開"])
    }

    @Test func interruptedOperationKeepsCheckpointAndUnsubmittedDraft() async throws {
        let fixture = try SubmissionFixture()
        defer { fixture.removeFiles() }
        let store = fixture.store
        store.instruction = "端末間の役割を考えてね"
        store.submitInstruction()
        await store.inferenceTask?.value
        let responseID = try #require(store.project.workItems.first?.id)
        for operation in [ResumableProjectOperation.modelInference, .projectValidation, .fileEditInference, .artifactPlanning] {
            store.library.updateSelectedProject { project in
                ProjectOperationCheckpointWorkflow.started(operation, referenceID: responseID, in: &project)
            }
            let before = store.project
            store.instruction = "続けて"
            store.submitInstruction()
            #expect(store.project == before)
            #expect(store.instruction == "続けて")
            #expect(store.notice?.message.contains("中断した作業") == true)
            #expect(store.acceptRemoteInstruction("続けて").status == .busy)
            #expect(store.project == before)
        }
        store.library.updateSelectedProject { project in
            ProjectOperationCheckpointWorkflow.started(.modelInference, referenceID: responseID, in: &project)
        }
        let conversationCount = store.project.conversation.count
        let iteration = store.project.creationLoop.iteration
        store.resumeInterruptedInference()
        #expect(store.project.creationLoop.phase == .localModelWorking)
        #expect(store.project.creationLoop.iteration == iteration)
        await store.inferenceTask?.value
        #expect(store.project.operationCheckpoint == nil)
        #expect(store.project.conversation.count == conversationCount + 1)
        #expect(store.project.workItems.first?.id == responseID)
        #expect(await fixture.provider.requests.count == 2)
        #expect(store.visibleConversationPerformance?.attempts.count == 1)
    }

    @Test func busySubmissionKeepsInputAndDoesNotCreateWork() throws {
        let fixture = try SubmissionFixture()
        defer { fixture.removeFiles() }
        let store = fixture.store
        let before = store.project
        store.generationPhase = .generating
        store.instruction = "続けて"
        store.submitInstruction()
        #expect(store.project == before)
        #expect(store.instruction == "続けて")
        #expect(store.notice?.message.contains("別のAI応答") == true)
    }
}

@MainActor
private struct SubmissionFixture {
    let directory: URL
    let repository: WorkspaceRepository
    let provider = SubmissionInferenceFixture()
    let store: WorkspaceStore

    init(hasModel: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Harness-Submission-\(UUID().uuidString)", isDirectory: true)
        repository = WorkspaceRepository(fileURL: directory.appendingPathComponent("workspace.json"))
        var project = HarnessProject.starter
        project.selectedModel = hasModel
            ? ModelSelection(identifier: "fixture", displayName: "Fixture", runtime: .ollama)
            : nil
        try repository.saveLibrary(ProjectLibrary(records: [ProjectRecord(project: project)]))
        store = WorkspaceStore(repository: repository, inferenceProvider: provider)
    }

    func removeFiles() { try? FileManager.default.removeItem(at: directory) }
}

private actor SubmissionInferenceFixture: ModelInferenceProvider {
    private(set) var requests: [InferenceRequest] = []

    func events(for request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            continuation.yield("案\(requests.count): 今は設計を確認しています。元の項目を見ながら、次の案を整理しよう。")
            continuation.finish()
        }
    }
}
