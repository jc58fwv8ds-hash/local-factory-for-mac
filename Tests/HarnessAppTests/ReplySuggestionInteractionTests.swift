import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

@MainActor
@Suite(.serialized)
struct ReplySuggestionInteractionTests {
    @Test func generatingAndSelectingOnlyDraftsThenEditedWordsUseTheExistingSubmissionPath() async throws {
        let fixture = try ReplySuggestionStoreFixture()
        defer { fixture.removeFiles() }
        let before = fixture.store.library
        fixture.store.generateReplySuggestions()
        await fixture.store.replySuggestions.task?.value
        let choice = try #require(fixture.store.replySuggestions.suggestions.first)
        #expect(fixture.store.useReplySuggestion(choice.id) == .applied)
        #expect(fixture.store.instruction == choice.instruction)
        #expect(fixture.store.library == before)
        #expect(try fixture.repository.loadLibrary() == before)
        #expect(await fixture.provider.requests.count == 1)

        fixture.store.instruction += " それと、説明は3文くらいで頼むね。"
        let edited = fixture.store.instruction
        fixture.store.submitInstruction()
        await fixture.store.inferenceTask?.value
        #expect(fixture.store.project.conversation.suffix(2).first?.content == edited)
        #expect(fixture.store.project.conversation.suffix(2).first?.origin == .user)
        #expect(fixture.store.project.creationLoop.iteration == before.selectedRecord!.project.creationLoop.iteration + 1)
        #expect(fixture.store.project.progress == before.selectedRecord!.project.progress)
        #expect(fixture.store.project.operationCheckpoint == nil)
        #expect(fixture.store.replySuggestions.suggestions.isEmpty)
        let requests = await fixture.provider.requests
        #expect(requests.count == 2 && requests.last?.structuredOutput == nil)
        #expect(requests.last?.messages.last?.content.hasPrefix(edited) == true)
        #expect(requests.last?.messages.last?.content.contains(ConversationResponseGuard.instructions) == true)
    }

    @Test func existingDraftNeedsConfirmationAndUntouchedChoicesCanBeSwitched() async throws {
        let fixture = try ReplySuggestionStoreFixture()
        defer { fixture.removeFiles() }
        fixture.store.generateReplySuggestions()
        await fixture.store.replySuggestions.task?.value
        let choices = fixture.store.replySuggestions.suggestions
        #expect(choices.count == 2)
        fixture.store.instruction = "こっちの文章は残してね〜"
        #expect(fixture.store.useReplySuggestion(choices[0].id) == .confirmationRequired)
        #expect(fixture.store.instruction == "こっちの文章は残してね〜")
        #expect(fixture.store.useReplySuggestion(choices[0].id, replacingDraft: true) == .applied)
        #expect(fixture.store.useReplySuggestion(choices[1].id) == .applied)
        #expect(fixture.store.instruction == choices[1].instruction)
        fixture.store.instruction += " あと、短めでね"
        #expect(fixture.store.useReplySuggestion(choices[0].id) == .confirmationRequired)
        #expect(fixture.store.instruction.hasSuffix("あと、短めでね"))
        #expect(await fixture.provider.requests.count == 1)
    }

    @Test func projectChangeDiscardsInFlightChoicesAndCannotReplaceTheNewDraft() async throws {
        let fixture = try ReplySuggestionStoreFixture(holdSuggestions: true)
        defer { fixture.removeFiles() }
        fixture.store.generateReplySuggestions()
        let task = fixture.store.replySuggestions.task
        try await ReplySuggestionFixtures.waitForRequest(fixture.provider)
        let newRecord = ProjectRecord(project: ReplySuggestionFixtures.project())
        fixture.store.library.add(newRecord)
        fixture.store.instruction = "新しい方の相談だよ"
        await task?.value
        #expect(!fixture.store.replySuggestions.isLoading)
        #expect(fixture.store.replySuggestions.suggestions.isEmpty)
        #expect(fixture.store.replySuggestions.context?.projectID == newRecord.id)
        #expect(fixture.store.instruction == "新しい方の相談だよ")
    }

    @Test func staleChoiceIDsAreRejectedAfterNewAnswerOrModelChange() async throws {
        let fixture = try ReplySuggestionStoreFixture()
        defer { fixture.removeFiles() }
        for changeModel in [false, true] {
            fixture.store.generateReplySuggestions()
            await fixture.store.replySuggestions.task?.value
            let id = try #require(fixture.store.replySuggestions.suggestions.first?.id)
            fixture.store.instruction = "自分の言葉は残す"
            fixture.store.library.updateSelectedProject { project in
                if changeModel {
                    project.selectedModel = ModelSelection(identifier: "different", displayName: "Different", runtime: .lmStudio)
                } else {
                    project.conversation.append(ConversationMessage(role: .assistant, content: "新しい返答だよ"))
                }
            }
            #expect(fixture.store.useReplySuggestion(id, replacingDraft: true) == .unavailable)
            #expect(fixture.store.instruction == "自分の言葉は残す")
            #expect(fixture.store.replySuggestions.suggestions.isEmpty)
        }
    }

    @Test func ordinarySubmissionCancelsOptionalInferenceWithoutWaitingForItsAnswer() async throws {
        let fixture = try ReplySuggestionStoreFixture(holdSuggestions: true)
        defer { fixture.removeFiles() }
        fixture.store.generateReplySuggestions()
        let suggestionTask = fixture.store.replySuggestions.task
        try await ReplySuggestionFixtures.waitForRequest(fixture.provider)
        fixture.store.instruction = "候補はいいや。今の案を短く教えてちょ"
        fixture.store.submitInstruction()
        await fixture.store.inferenceTask?.value
        await suggestionTask?.value
        #expect(fixture.store.project.conversation.suffix(2).first?.content == "候補はいいや。今の案を短く教えてちょ")
        #expect(!fixture.store.isGenerating && !fixture.store.replySuggestions.isLoading)
        #expect(fixture.store.replySuggestions.suggestions.isEmpty)
        #expect(await fixture.provider.requests.count == 2)
    }

    @Test func cancelAndFailureDoNotChangeProjectOrBlockTyping() async throws {
        let fixture = try ReplySuggestionStoreFixture(holdSuggestions: true)
        defer { fixture.removeFiles() }
        let before = fixture.store.project
        fixture.store.generateReplySuggestions()
        let task = fixture.store.replySuggestions.task
        try await ReplySuggestionFixtures.waitForRequest(fixture.provider)
        fixture.store.replySuggestions.cancel()
        await task?.value
        #expect(fixture.store.replySuggestions.suggestions.isEmpty)
        #expect(!fixture.store.replySuggestions.isLoading && fixture.store.project == before)

        let failed = try ReplySuggestionStoreFixture(json: "broken response")
        defer { failed.removeFiles() }
        let failedBefore = failed.store.project
        failed.store.instruction = "入力中の文章"
        failed.store.generateReplySuggestions()
        await failed.store.replySuggestions.task?.value
        #expect(failed.store.replySuggestions.message != nil)
        #expect(failed.store.replySuggestions.suggestions.isEmpty)
        #expect(failed.store.project == failedBefore && failed.store.instruction == "入力中の文章")
        #expect(!failed.store.isGenerating)
    }

    @Test func lateServiceCompletionCannotReplaceNewContextOrClearNewLoadingState() async throws {
        let service = DeferredReplySuggestionService()
        let session = ReplySuggestionSession(service: service)
        let first = try #require(ReplySuggestionContext(project: ReplySuggestionFixtures.project()))
        let second = try #require(ReplySuggestionContext(project: ReplySuggestionFixtures.project()))
        session.generate(for: first)
        let oldTask = session.task
        try await service.waitFor(first.projectID)
        session.generate(for: second)
        let newTask = session.task
        try await service.waitFor(second.projectID)
        await service.finish(first.projectID, title: "古い案")
        await oldTask?.value
        #expect(session.isLoading && session.suggestions.isEmpty)
        await service.finish(second.projectID, title: "新しい案")
        await newTask?.value
        #expect(session.suggestions.first?.title == "新しい案")
        #expect(session.context == second && !session.isLoading)
    }
}

private actor DeferredReplySuggestionService: ReplySuggestionProviding {
    private var continuations: [UUID: CheckedContinuation<[ReplySuggestion], Never>] = [:]

    func suggestions(for context: ReplySuggestionContext) async throws -> [ReplySuggestion] {
        await withCheckedContinuation { continuations[context.projectID] = $0 }
    }

    func finish(_ id: UUID, title: String) {
        continuations.removeValue(forKey: id)?.resume(returning: [ReplySuggestion(title: title, instruction: "説明してね", effect: "違いが分かるよ")])
    }

    func waitFor(_ id: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while continuations[id] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(continuations[id] != nil)
    }
}
