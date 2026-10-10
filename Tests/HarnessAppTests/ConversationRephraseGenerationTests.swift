import HarnessCore
import Testing
@testable import HarnessApp

@MainActor
@Suite(.serialized)
struct ConversationRephraseGenerationTests {
    private let previous = "遅い原因はまだ断定できません。入力の内訳を見てから判断します。"
    private let rephrased = "何が遅さにつながるかは、まだ決められません。まず入力の中身を比べて確かめます。"

    @Test func unchangedRephraseIsRetriedOnceWithoutDuplicatingWork() async throws {
        let fixture = try ConversationGenerationFixture(
            previous: previous, replies: [previous, rephrased]
        )
        defer { fixture.removeFiles() }
        let before = fixture.store.project
        fixture.store.instruction = "今の返答を難しい言葉なしの2文で言い直して"
        fixture.store.submitInstruction()
        let responseID = fixture.store.project.workItems.first?.id
        await fixture.store.inferenceTask?.value

        let project = fixture.store.project
        let requests = await fixture.provider.requests
        #expect(requests.count == 2)
        #expect(project.conversation.map(\.content) == before.conversation.map(\.content) + [
            "今の返答を難しい言葉なしの2文で言い直して", rephrased
        ])
        #expect(project.workItems.count == before.workItems.count + 1)
        #expect(project.workItems.first?.id == responseID && project.workItems.first?.status == .completed)
        #expect(project.progress == before.progress && project.stage == before.stage)
        #expect(project.creationLoop.iteration == before.creationLoop.iteration + 1)
        #expect(Array(requests[1].messages.dropLast(2)) == requests[0].messages)
        #expect(requests[1].messages[requests[1].messages.count - 2].content == previous)
        #expect(requests[1].messages.last?.content.contains("別の表現") == true)
        #expect(fixture.store.visibleConversationPerformance?.attempts.count == 2)
    }

    @Test func secondUnchangedRephraseIsNotSaved() async throws {
        let fixture = try ConversationGenerationFixture(
            previous: previous, replies: [previous, previous]
        )
        defer { fixture.removeFiles() }
        fixture.store.instruction = "今の説明を別の言い方で2文にして"
        fixture.store.submitInstruction()
        await fixture.store.inferenceTask?.value

        #expect(await fixture.provider.requests.count == 2)
        #expect(fixture.store.project.conversation.last?.role == .user)
        #expect(fixture.store.project.workItems.first?.status == .needsAttention)
        #expect(fixture.store.notice?.message == InferenceError.unchangedRephrase.localizedDescription)
        #expect(fixture.store.visibleConversationPerformance == nil)
        #expect(!fixture.store.isGenerating)
    }

    @Test func explicitRequestForTheSameAnswerDoesNotRetry() async throws {
        let fixture = try ConversationGenerationFixture(previous: previous, replies: [previous])
        defer { fixture.removeFiles() }
        fixture.store.instruction = "同じ説明をもう一度して"
        fixture.store.submitInstruction()
        await fixture.store.inferenceTask?.value

        #expect(await fixture.provider.requests.count == 1)
        #expect(fixture.store.project.conversation.last?.content == previous)
        #expect(fixture.store.project.workItems.first?.status == .completed)
    }

    @Test func rephraseRetryStillHasToMeetTheRequestedSentenceCount() async throws {
        let threeSentences = "まだ断定できません。入力を比べます。その後で判断します。"
        let fixture = try ConversationGenerationFixture(
            previous: previous, replies: [previous, threeSentences]
        )
        defer { fixture.removeFiles() }
        fixture.store.instruction = "今の返答を別の言い方の2文にして"
        fixture.store.submitInstruction()
        await fixture.store.inferenceTask?.value

        #expect(await fixture.provider.requests.count == 2)
        #expect(fixture.store.project.conversation.last?.role == .user)
        #expect(fixture.store.notice?.message == InferenceError.responseSentenceCount(
            expected: 2, actual: 3
        ).localizedDescription)
        #expect(fixture.store.visibleConversationPerformance == nil)
    }
}
