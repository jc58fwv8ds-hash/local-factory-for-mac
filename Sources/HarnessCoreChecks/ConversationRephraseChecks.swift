import HarnessCore

enum ConversationRephraseChecks {
    static func run() throws {
        let previous = "原因はまだ断定できません。入力を確認して判断します。"
        var project = HarnessProject.starter
        project.conversation = [
            ConversationMessage(role: .user, content: "待ち時間を説明して"),
            ConversationMessage(role: .assistant, content: previous),
            ConversationMessage(role: .user, content: "今の返答を別の言い方の2文にして")
        ]
        let policy = try require(ConversationRephrasePolicy(project: project))
        let request = InferenceRequest(
            runtime: .ollama,
            modelIdentifier: "fixture",
            messages: ProjectPromptBuilder.messages(for: project)
        )
        let retry = policy.refinementRequest(from: request, response: previous)
        try expect(
            policy.repeats(previous)
                && !policy.repeats("判断はまだできません。まず入力を確認します。")
                && retry.messages.count == request.messages.count + 2
                && retry.messages.last?.content.contains("別の表現") == true
                && !ConversationRephrasePolicy.requestsRephrase("同じ説明をもう一度して"),
            "Explicit rephrase quality checking did not remain bounded and opt-in"
        )
        print("✓ Explicit rephrases retry one unchanged answer without treating repetition requests as errors")
    }
}
