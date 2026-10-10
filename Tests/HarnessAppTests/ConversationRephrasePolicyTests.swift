import HarnessCore
import Testing

struct ConversationRephrasePolicyTests {
    @Test(arguments: [
        "今の返答を言い直して", "もっと簡単な言葉に言い換えて", "別の言い方で2文にして",
        "表現を変えてください", "Please rephrase this response"
    ])
    func explicitRephraseRequestsAreRecognized(_ instruction: String) {
        #expect(ConversationRephrasePolicy.requestsRephrase(instruction))
    }

    @Test(arguments: [
        "同じ説明をもう一度して", "そのままもう一度見せて", "一字一句変えないで",
        "言い直さないで", "別の言い方は不要です", "前の案を実装して"
    ])
    func repetitionNegativeAndOrdinaryRequestsAreNotRephrases(_ instruction: String) {
        #expect(!ConversationRephrasePolicy.requestsRephrase(instruction))
    }

    @Test func directPreviousLocalAnswerIsRequired() throws {
        var fixtureProject = project(instruction: "今の返答を言い直して")
        let policy = try #require(ConversationRephrasePolicy(project: fixtureProject))
        #expect(policy.previousResponse.content == "前の回答です。")

        fixtureProject.conversation.insert(
            ConversationMessage(role: .assistant, content: "外部の回答", origin: .externalReview),
            at: fixtureProject.conversation.count - 1
        )
        #expect(ConversationRephrasePolicy(project: fixtureProject) == nil)

        fixtureProject = project(instruction: "今の返答を言い直して")
        fixtureProject.conversation.insert(
            ConversationMessage(role: .user, content: "未回答の別件"),
            at: fixtureProject.conversation.count - 1
        )
        #expect(ConversationRephrasePolicy(project: fixtureProject) == nil)
    }

    @Test func comparisonKeepsMeaningfulDifferences() throws {
        let policy = try #require(ConversationRephrasePolicy(
            project: project(previous: "候補は3つ。\nIDはAです。", instruction: "言い直して")
        ))
        #expect(policy.repeats(" \n候補は3つ。\r\nIDはAです。\n"))
        #expect(!policy.repeats("候補は4つ。\nIDはAです。"))
        #expect(!policy.repeats("候補は3つ。\nIDはaです。"))
    }

    @Test func refinementKeepsRequestAndBoundsTheUncommittedDraft() throws {
        let policy = try #require(ConversationRephrasePolicy(project: project(instruction: "2文で言い直して")))
        let request = InferenceRequest(
            runtime: .lmStudio,
            modelIdentifier: "fixture",
            messages: [InferenceMessage(role: .user, content: "2文で言い直して")],
            maximumOutputTokens: 768
        )
        let revised = policy.refinementRequest(
            from: request, response: String(repeating: "前の回答です。", count: 400)
        )
        #expect(Array(revised.messages.dropLast(2)) == request.messages)
        #expect(revised.messages[revised.messages.count - 2].role == .assistant)
        #expect(revised.messages[revised.messages.count - 2].content.count <= 2_000)
        #expect(revised.messages.last?.content.contains("別の表現") == true)
        #expect(revised.messages.last?.content.contains("実行の承認ではありません") == true)
        #expect(revised.maximumOutputTokens == 768)
    }

    private func project(
        previous: String = "前の回答です。",
        instruction: String
    ) -> HarnessProject {
        var project = HarnessProject.starter
        project.conversation = [
            ConversationMessage(role: .user, content: "最初の質問"),
            ConversationMessage(role: .assistant, content: previous),
            ConversationMessage(role: .user, content: instruction)
        ]
        return project
    }
}
