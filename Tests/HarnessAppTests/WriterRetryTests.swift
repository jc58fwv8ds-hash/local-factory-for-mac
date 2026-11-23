@testable import HarnessCore
import Testing

struct WriterRetryTests {
    @Test func aRetryAfterAnUnchangedAnswerIsAskedWithSomeFreedom() {
        #expect(WriterRetry.temperature(for: [InferenceMessage(role: .user, content: "直して")]) == nil)
        #expect(WriterRetry.temperature(for: [InferenceMessage(role: .user, content: "直して\n前の案はファイルを変えていませんでした。")]) == 0.6)
    }
}
