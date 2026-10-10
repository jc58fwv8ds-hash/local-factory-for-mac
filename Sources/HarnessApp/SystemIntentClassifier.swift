import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Asks the on-device system language model (Apple Foundation Models, Neural Engine; it does not compete with the GPU model)
/// whether a chat message asks to change the connected project's code. Used only for messages the keyword router cannot
/// decide; nil when the model is unavailable or does not answer within the time limit, and the caller then treats the
/// message as conversation.
enum SystemIntentClassifier {
    static let timeout: Duration = .seconds(3)

    static let instructions = "あなたは分類器です。ソフトウェアのプロジェクトについての発言が、コードを変える依頼なら「修正」、質問・相談・雑談なら「会話」と一語だけ答えます。"

    /// Loads the on-device model ahead of the first message (the first call otherwise takes ~4 s, past the time limit).
    static func prewarm() {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability else { return }
        LanguageModelSession(instructions: instructions).prewarm()
        #endif
    }

    static func isCodeChange(_ text: String) async -> Bool? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability else { return nil }
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: instructions)
                guard let answer = try? await session.respond(to: text) else { return nil }
                return answer.content.contains("修正") ? true : (answer.content.contains("会話") ? false : nil)
            }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #else
        return nil
        #endif
    }
}
