import Foundation

/// A direct request for different wording must not silently commit the prior wording unchanged.
public struct ConversationRephrasePolicy: Sendable {
    public let instruction: ConversationMessage
    public let previousResponse: ConversationMessage

    public init?(project: HarnessProject) {
        let users = ProjectInstructionContext.userMessages(in: project)
        guard let latest = users.last,
              Self.requestsRephrase(latest.content),
              let latestIndex = project.conversation.firstIndex(where: { $0.id == latest.id }) else {
            return nil
        }
        instruction = latest
        let userIDs = Set(users.map(\.id))
        for message in project.conversation[..<latestIndex].reversed() {
            if userIDs.contains(message.id) { return nil }
            if message.role == .assistant {
                guard message.origin == .localModel,
                      !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                previousResponse = message
                return
            }
        }
        return nil
    }

    public static func requestsRephrase(_ instruction: String) -> Bool {
        let normalized = instruction.lowercased()
        let repeatRequests = [
            "同じ説明をもう一度", "同じ返答をもう一度", "同じ回答をもう一度",
            "同じ文章をもう一度", "そのままもう一度", "一字一句", "繰り返して", "再掲して",
            "言い直さないで", "言い換えないで", "書き直さないで", "別の言い方は不要",
            "repeat the same", "show the same answer"
        ]
        guard !repeatRequests.contains(where: normalized.contains) else { return false }
        let rephraseRequests = [
            "言い直して", "言い換えて", "書き直して", "表現を変えて",
            "別の言い方", "違う言い方", "rephrase", "rewrite the answer", "different wording"
        ]
        return rephraseRequests.contains(where: normalized.contains)
    }

    public func repeats(_ response: String) -> Bool {
        ConversationResponseIdentity.isSame(response, as: previousResponse.content)
    }

    public func refinementRequest(
        from request: InferenceRequest,
        response: String
    ) -> InferenceRequest {
        let draft = PromptReferenceText.excerpt(
            ConversationResponseText.visibleText(response), maximumCharacters: 2_000
        )
        return InferenceRequest(
            runtime: request.runtime,
            modelIdentifier: request.modelIdentifier,
            messages: request.messages + [
                InferenceMessage(role: .assistant, content: draft),
                InferenceMessage(role: .user, content: """
                    Harnessの返答検査で、ユーザーは明示的に言い直しを頼みましたが、直前の案は前の回答と同じ文章でした。まだ保存していません。
                    元の意味、未調査・未確認の区別、指定された文数と短さを保ちながら、語順や言葉を変えた別の表現で本文だけを返してください。
                    新しい事実、見出し、箇条書き、前置きは足さないでください。
                    この再検討は新しい制作指示や実行の承認ではありません。
                    """)
            ],
            maximumOutputTokens: request.maximumOutputTokens,
            structuredOutput: request.structuredOutput,
            images: request.images
        )
    }
}
