import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

@MainActor
@Suite(.serialized)
struct ContinuationGenerationTests {
    private let previous = "次はDailyRecordの具体的なフィールドを決めよう。"
    private let next = "仮の案として、ID・日付・記録の一覧を持たせよう。日ごとの検索と重複の防止がしやすくなるよ。"

    @Test func repeatedAnswerIsRefinedOnceWithoutAnotherInstructionOrProductionProgress() async throws {
        let fixture = try ConversationGenerationFixture(previous: previous, replies: [previous, next])
        defer { fixture.removeFiles() }
        let before = fixture.store.project
        fixture.store.instruction = "続けてちょ"
        fixture.store.submitInstruction()
        let responseID = fixture.store.project.workItems.first?.id
        await fixture.store.inferenceTask?.value
        let project = fixture.store.project
        #expect(project.conversation.map(\.content) == before.conversation.map(\.content) + ["続けてちょ", next])
        #expect(project.workItems.count == before.workItems.count + 1)
        #expect(project.workItems.first?.id == responseID && project.workItems.first?.status == .completed)
        #expect(project.workItems.filter { $0.id != responseID } == before.workItems)
        #expect(project.progress == before.progress && project.stage == before.stage)
        #expect(project.creationLoop.iteration == before.creationLoop.iteration + 1)
        #expect(project.operationCheckpoint == nil && !fixture.store.isGenerating)
        let requests = await fixture.provider.requests
        #expect(requests.count == 2)
        let timing = try #require(fixture.store.visibleConversationPerformance)
        #expect(timing.attempts.count == 2)
        #expect(timing.responseID == project.conversation.last?.id)
        #expect(timing.attempts.map(\.promptCharacters) == requests.map { request in
            request.messages.reduce(0) { $0 + $1.content.count }
        })
        #expect(timing.attempts.allSatisfy { $0.firstContentSeconds != nil })
        #expect(fixture.store.generationTimings.isEmpty)
        #expect(Array(requests[1].messages.dropLast()) == requests[0].messages)
        #expect(try fixture.repository.loadLibrary()?.selectedRecord?.project == project)
    }

    @Test func secondDuplicateStopsWithoutSavingItOrClaimingSuccess() async throws {
        let fixture = try ConversationGenerationFixture(previous: previous, replies: [previous, previous, next])
        defer { fixture.removeFiles() }
        fixture.store.instruction = "続けて"
        fixture.store.submitInstruction()
        await fixture.store.inferenceTask?.value
        #expect(await fixture.provider.requests.count == 2)
        #expect(fixture.store.project.conversation.count == 3)
        #expect(fixture.store.project.conversation.last?.role == .user)
        #expect(fixture.store.project.workItems.first?.status == .needsAttention)
        #expect(fixture.store.notice?.message == InferenceError.repeatedResponse.localizedDescription)
        #expect(fixture.store.lastConversationPerformance == nil && fixture.store.generationTimings.isEmpty)
        #expect(!fixture.store.project.currentActivity.contains("接続"))
        #expect(!fixture.store.isGenerating && fixture.store.streamingResponse.isEmpty)
        #expect(fixture.store.project.operationCheckpoint == nil)
        #expect(try fixture.repository.loadLibrary()?.selectedRecord?.project == fixture.store.project)
    }

    @Test func stoppingTheRefinementKeepsOriginalCheckpointAndDropsPartialAnswer() async throws {
        let fixture = try ConversationGenerationFixture(previous: previous, replies: [previous, "途中の案"], holdLast: true)
        defer { fixture.removeFiles() }
        fixture.store.instruction = "続けよ"
        fixture.store.submitInstruction()
        let checkpoint = fixture.store.project.operationCheckpoint
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixture.store.streamingResponse != "途中の案", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.store.generationPhase == .revisingResponse)
        #expect(fixture.store.generationStatusMessage.contains("1回だけ"))
        #expect(fixture.store.streamingResponse == "途中の案")
        #expect(fixture.store.project.operationCheckpoint == checkpoint)
        fixture.store.stopGeneration()
        await fixture.store.inferenceTask?.value
        #expect(await fixture.provider.requests.count == 2)
        #expect(fixture.store.project.conversation.count == 3)
        #expect(fixture.store.project.workItems.first?.status == .needsAttention)
        #expect(fixture.store.project.operationCheckpoint == checkpoint)
        #expect(!fixture.store.isGenerating && fixture.store.streamingResponse.isEmpty)
        #expect(fixture.store.visibleConversationPerformance == nil && fixture.store.generationTimings.isEmpty)
        #expect(try fixture.repository.loadLibrary()?.selectedRecord?.project == fixture.store.project)
    }

    @Test func novelContinuationAndExplicitRepetitionDoNotCauseExtraRequests() async throws {
        for (instruction, reply) in [("続けて", next), ("同じ説明をもう一度して", previous)] {
            let fixture = try ConversationGenerationFixture(previous: previous, replies: [reply])
            defer { fixture.removeFiles() }
            fixture.store.instruction = instruction
            fixture.store.submitInstruction()
            await fixture.store.inferenceTask?.value
            #expect(await fixture.provider.requests.count == 1)
            #expect(fixture.store.project.conversation.last?.content == reply)
            #expect(fixture.store.project.workItems.first?.status == .completed)
        }
    }

    @Test func refinementFailureDoesNotCommitTheEarlierDuplicate() async throws {
        let fixture = try ConversationGenerationFixture(previous: previous, replies: [previous])
        defer { fixture.removeFiles() }
        fixture.store.instruction = "続けて"
        fixture.store.submitInstruction()
        await fixture.store.inferenceTask?.value
        #expect(await fixture.provider.requests.count == 2)
        #expect(fixture.store.project.conversation.count == 3)
        #expect(fixture.store.project.workItems.first?.status == .needsAttention)
        #expect(fixture.store.notice?.message == InferenceError.invalidResponse.localizedDescription)
        #expect(fixture.store.lastConversationPerformance == nil && fixture.store.generationTimings.isEmpty)
        #expect(!fixture.store.isGenerating && fixture.store.streamingResponse.isEmpty)
    }

    @Test func echoedReferenceLabelsAreNotSavedToConversationOrActivity() async throws {
        let heading = "過去のローカル回答（提案・参考。実装・実行・検証の証拠ではありません）:\n"
        let fixture = try ConversationGenerationFixture(previous: previous, replies: [heading + next])
        defer { fixture.removeFiles() }
        fixture.store.instruction = "前の案との違いを教えて"
        fixture.store.submitInstruction()
        await fixture.store.inferenceTask?.value
        #expect(fixture.store.project.conversation.last?.content == next)
        #expect(fixture.store.project.activity.first?.detail.contains("過去のローカル回答") == false)
        #expect(try fixture.repository.loadLibrary()?.selectedRecord?.project == fixture.store.project)
    }

    @Test func partialInternalLabelCanBeStoppedWithoutDisplayingOrSavingIt() async throws {
        let fixture = try ConversationGenerationFixture(previous: previous, replies: ["過去のローカル回答（提案"], holdLast: true)
        defer { fixture.removeFiles() }
        fixture.store.instruction = "前の案との違いを教えて"
        fixture.store.submitInstruction()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await fixture.provider.requests.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.store.isGenerating && fixture.store.streamingResponse.isEmpty)
        let checkpoint = fixture.store.project.operationCheckpoint
        fixture.store.stopGeneration()
        await fixture.store.inferenceTask?.value
        #expect(fixture.store.project.operationCheckpoint == checkpoint)
        #expect(fixture.store.project.conversation.last?.role == .user)
    }

    @Test func internalLabelAloneIsNotAcceptedAsACompleteAnswer() async throws {
        let label = "過去のローカル回答（提案・参考。実装・実行・検証の証拠ではありません）:\n"
        let fixture = try ConversationGenerationFixture(previous: previous, replies: [label])
        defer { fixture.removeFiles() }
        fixture.store.instruction = "前の案との違いを教えて"
        fixture.store.submitInstruction()
        await fixture.store.inferenceTask?.value
        #expect(fixture.store.project.conversation.last?.role == .user)
        #expect(fixture.store.project.workItems.first?.status == .needsAttention)
        #expect(fixture.store.notice?.message == InferenceError.emptyResponse.localizedDescription)
    }

    @Test func explicitSentenceCountIsRewrittenOnceWithoutChangingTheInstruction() async throws {
        let first = "数値は未測定でした。比較はこれからです。同じ条件で前後を測ります。"
        let revised = "数値は未測定でした。同じ条件で変更前後を測るまで効果は分かりません。"
        let fixture = try ConversationGenerationFixture(previous: previous, replies: [first, revised])
        defer { fixture.removeFiles() }
        fixture.store.instruction = "未測定なら訂正して、比較方法を2文で教えて"
        fixture.store.submitInstruction()
        await fixture.store.inferenceTask?.value

        let requests = await fixture.provider.requests
        #expect(requests.count == 2)
        #expect(requests[1].messages[requests[1].messages.count - 2].content == first)
        #expect(requests[1].messages.last?.content.contains("ちょうど2文") == true)
        #expect(fixture.store.project.conversation.last?.content == revised)
        #expect(fixture.store.visibleConversationPerformance?.attempts.count == 2)
        #expect(fixture.store.project.workItems.first?.status == .completed)
    }

    @Test func secondSentenceCountMismatchIsNotSavedAsACompletedAnswer() async throws {
        let threeSentences = "ひとつです。ふたつです。みっつです。"
        let fixture = try ConversationGenerationFixture(
            previous: previous, replies: [threeSentences, threeSentences]
        )
        defer { fixture.removeFiles() }
        fixture.store.instruction = "2文で教えて"
        fixture.store.submitInstruction()
        await fixture.store.inferenceTask?.value

        #expect(await fixture.provider.requests.count == 2)
        #expect(fixture.store.project.conversation.last?.role == .user)
        #expect(fixture.store.project.workItems.first?.status == .needsAttention)
        #expect(fixture.store.notice?.message == InferenceError.responseSentenceCount(
            expected: 2, actual: 3
        ).localizedDescription)
        #expect(fixture.store.visibleConversationPerformance == nil)
    }
}

@MainActor
struct ConversationGenerationFixture {
    let directory: URL
    let repository: WorkspaceRepository
    let provider: ConversationInferenceFixture
    let store: WorkspaceStore

    init(previous: String, replies: [String], holdLast: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Harness-Continuation-\(UUID().uuidString)", isDirectory: true)
        repository = WorkspaceRepository(fileURL: directory.appendingPathComponent("workspace.json"))
        provider = ConversationInferenceFixture(replies: replies, holdLast: holdLast)
        var project = HarnessProject.starter
        project.selectedModel = ModelSelection(identifier: "fixture", displayName: "Fixture", runtime: .ollama)
        project.conversation = [
            ConversationMessage(role: .user, content: "設計の案を短く教えて。まだファイルは変えないでね。"),
            ConversationMessage(role: .assistant, content: previous)
        ]
        try repository.saveLibrary(ProjectLibrary(records: [ProjectRecord(project: project)]))
        store = WorkspaceStore(repository: repository, inferenceProvider: provider)
    }

    func removeFiles() { try? FileManager.default.removeItem(at: directory) }
}

actor ConversationInferenceFixture: ModelInferenceProvider {
    private(set) var requests: [InferenceRequest] = []
    let replies: [String]
    let holdLast: Bool
    private var heldContinuation: AsyncThrowingStream<String, Error>.Continuation?

    init(replies: [String], holdLast: Bool) {
        self.replies = replies
        self.holdLast = holdLast
    }

    func events(for request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        let index = requests.count
        requests.append(request)
        let stream = AsyncThrowingStream<String, Error>.makeStream()
        guard replies.indices.contains(index) else {
            stream.continuation.finish(throwing: InferenceError.invalidResponse)
            return stream.stream
        }
        stream.continuation.yield(replies[index])
        if holdLast, index == replies.count - 1 {
            heldContinuation = stream.continuation
        } else {
            stream.continuation.finish()
        }
        return stream.stream
    }
}
