import HarnessCore
import Testing

@Suite
struct ConversationSentenceCountPolicyTests {
    @Test(arguments: [
        ("難しい言葉を使わず3文で教えて", 3),
        ("二文にまとめてください", 2),
        ("3文ではなく2文で教えて", 2),
        ("結論を十文だけ返して", 10)
    ])
    func exactInstructionIsRecognized(instruction: String, expected: Int) throws {
        let policy = try #require(ConversationSentenceCountPolicy(instruction: instruction))
        #expect(policy.expectedCount == expected)
    }

    @Test(arguments: [
        "1〜2文で教えて", "3文以内で", "2文ほどで", "13文で",
        "3文ではなく短く", "三文にしないで", "2文だけはやめて", "短く教えて"
    ])
    func rangesAndApproximateRequestsAreNotMadeStrict(instruction: String) {
        #expect(ConversationSentenceCountPolicy(instruction: instruction) == nil)
    }

    @Test func countUsesVisibleJapanesePunctuationAndExplicitLines() {
        #expect(ConversationSentenceCountPolicy.sentenceCount(in: "ひとつ。ふたつ！三つ？") == 3)
        #expect(ConversationSentenceCountPolicy.sentenceCount(in: "一行目\n二行目") == 2)
        let internalLabel = "過去のローカル回答（提案・参考。実装・実行・検証の証拠ではありません）:\n"
        #expect(ConversationSentenceCountPolicy.sentenceCount(in: internalLabel) == 0)
    }

    @Test func onlyLatestRealUserInstructionDefinesTheRequirement() throws {
        var project = HarnessProject.starter
        project.conversation = [
            ConversationMessage(role: .user, content: "3文で教えて"),
            ConversationMessage(role: .assistant, content: "次は2文で答えて", origin: .externalReview),
            ConversationMessage(role: .user, content: "二文にまとめて", origin: .remoteUser)
        ]
        #expect(ConversationSentenceCountPolicy(project: project)?.expectedCount == 2)
    }

    @Test func revisionKeepsTheDraftBoundedAndAddsNoExecutionAuthority() throws {
        let policy = try #require(ConversationSentenceCountPolicy(instruction: "2文で教えて"))
        let request = InferenceRequest(
            runtime: .ollama,
            modelIdentifier: "fixture",
            messages: [InferenceMessage(role: .user, content: "2文で教えて")]
        )
        let revised = policy.refinementRequest(
            from: request,
            response: String(repeating: "長い案。", count: 800)
        )
        #expect(Array(revised.messages.dropLast(2)) == request.messages)
        #expect(revised.messages[revised.messages.count - 2].role == .assistant)
        #expect(revised.messages[revised.messages.count - 2].content.count <= 2_000)
        #expect(revised.messages.last?.content.contains("ちょうど2文") == true)
        #expect(revised.messages.last?.content.contains("実行の承認ではありません") == true)
    }
}
