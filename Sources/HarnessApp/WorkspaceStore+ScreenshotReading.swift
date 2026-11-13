import Foundation
import HarnessCore

/// What a model that sees pictures makes of a screenshot sent with a code request: the screen, and the markup drawn on it
/// (2026-11-11, the user: 「画像にマークアップ等で修正点を書き込んだ際にそれをちゃんと読み込むかって大事じゃない？」).
/// Text recognition alone reads written words but not what a circle or an arrow points at.
extension WorkspaceStore {
    /// Each picture on its own, named 画像1, 画像2… in the order they were attached, so a request can say which it means.
    func describeScreenshots(_ images: [InferenceImage], request: String) async -> String? {
        var parts: [String] = []
        for (index, image) in images.enumerated() {
            if let seen = await describeScreenshot(image, request: request) {
                parts.append((images.count > 1 ? "画像\(index + 1)(\(image.descriptor.displayName)):\n" : "") + seen)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// The model that reads pictures: the catalog's prompt writer (a 9B model with its picture part, 2026-11-07).
    var pictureReadingModel: ModelSelection? {
        let settings = purposeSettings
        return settings.catalog.roles?["promptWriter"].flatMap { settings.catalog.option(id: $0, for: .writing)?.selection }
    }

    private func describeScreenshot(_ image: InferenceImage, request: String) async -> String? {
        guard let model = pictureReadingModel ?? purposeSettings.chosen(.conversation)?.selection else { return nil }
        let prompt = """
        これはアプリの画面写真です。利用者はこの画面について次のように頼んでいます: 「\(request.prefix(400))」
        日本語で、箇条書きで答えてください。
        1. 画面の上から下へ、何がどこにどのくらいの大きさで表示されているか(ボタン、文字の枠、余白など)。
        2. 赤や色の線、丸、四角、矢印、手書きの文字など、あとから書き込まれた印があれば、その一つひとつについて、何を囲んだり指したりしていて、何と書いてあるか。書き込みがなければ「書き込みなし」。
        3. 利用者の頼みに関係しそうな、見た目の問題(はみ出し、切れている文字、狭い所、空いている所)。
        見えないことは書かないでください。
        """
        let request = InferenceRequest(runtime: model.runtime, modelIdentifier: model.identifier,
                                       messages: [InferenceMessage(role: .user, content: prompt)],
                                       maximumOutputTokens: 700, images: [image], temperature: 0)
        var answer = ""
        do { for try await piece in await inferenceProvider.events(for: request) { answer += piece } } catch { return nil }
        let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// A message that asks for several things, split into requests that can each be fixed on its own, in the person's
    /// words (2026-11-12, the user: the chat and its pictures sent as they are, and the Factory splits and runs them).
    /// One request, or the message as it is when the model gives nothing usable.
    func splitRequests(_ text: String, pictures: String?) async -> [String] {
        guard RequestSplitting.mayHoldSeveral(text) else { return [text] }
        let settings = purposeSettings
        guard let model = settings.chosen(.conversation)?.selection ?? project.selectedModel else { return [text] }
        let prompt = RequestSplitting.prompt(text, pictures: pictures)
        let request = InferenceRequest(runtime: model.runtime, modelIdentifier: model.identifier,
                                       messages: [InferenceMessage(role: .user, content: prompt)],
                                       maximumOutputTokens: 900, temperature: 0)
        var answer = ""
        do { for try await piece in await inferenceProvider.events(for: request) { answer += piece } } catch { return [text] }
        return RequestSplitting.ownAsks(RequestSplitting.parse(answer) ?? [text], in: text)
    }
}
