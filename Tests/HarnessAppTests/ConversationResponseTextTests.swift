import Foundation
import HarnessCore
import Testing

struct ConversationResponseTextTests {
    private let heading = "過去のローカル回答（提案・参考。実装・実行・検証の証拠ではありません）:\n"
    private let previousHeading = "前回のローカル回答（提案・参考。実装・実行・検証の証拠ではありません）:\n"

    @Test func exactLeadingLabelsAreRemovedWithoutEditingTheBody() {
        let body = "さっきのはまだ案の話だね。\n  let label = \"a  b\"\n"
        for label in [heading, previousHeading, heading.replacingOccurrences(of: "\n", with: "\r\n")] {
            #expect(ConversationResponseText.visibleText("\n " + label + body) == body)
        }
    }

    @Test func partialLabelsAreHiddenOnlyUntilTheStreamEnds() {
        for count in 1..<heading.count {
            let fragment = String(heading.prefix(count))
            #expect(ConversationResponseText.visibleText(fragment, isComplete: false).isEmpty)
        }
        #expect(ConversationResponseText.visibleText("過去") == "過去")
        #expect(ConversationResponseText.visibleText("前回の話をもう少し説明するね", isComplete: false) == "前回の話をもう少し説明するね")
        #expect(ConversationResponseText.visibleText(heading).isEmpty)
        #expect(ConversationResponseText.visibleText(heading.trimmingCharacters(in: .newlines)).isEmpty)
    }

    @Test func ordinaryQuotedEmbeddedAndCodeContentRemainUnchanged() {
        for body in ["\n  普通の回答\n", "> " + heading, "```text\n" + heading + "```", "この見出しの意味は\n" + heading] {
            #expect(ConversationResponseText.visibleText(body) == body)
        }
    }

    @Test func repeatedLeadingLabelsDoNotAccumulateAcrossConversationTurns() {
        #expect(ConversationResponseText.visibleText(heading + previousHeading + "案だけだよ。") == "案だけだよ。")
    }

    @Test func labelledHistoricalAnswersCannotEvadeTheDuplicateGuard() throws {
        var project = HarnessProject.starter
        project.conversation = [
            ConversationMessage(role: .user, content: "案を考えてね"),
            ConversationMessage(role: .assistant, content: heading + "前の案です。"),
            ConversationMessage(role: .user, content: "続けてちょ")
        ]
        let policy = try #require(ContinuationResponsePolicy(project: project))
        #expect(policy.repeats("前の案です。"))
        #expect(policy.repeats(previousHeading + "前の案です。"))
        #expect(!policy.repeats("次の案です。"))
    }
}
