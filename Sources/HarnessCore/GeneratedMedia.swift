import Foundation

/// Images and videos in a conversation (2026-11-05, the user: a chat model answered 「動画ができました」 with a made-up file
/// because it was copying the app's own notes; nothing had been made).
public enum GeneratedMedia {
    public enum Kind: Sendable, Equatable { case image, video }

    /// The note the app writes when a file is really finished.
    public static func isNote(_ text: String) -> Bool {
        text.hasPrefix("画像ができました") || text.hasPrefix("動画ができました")
    }

    public static func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    /// The steps a picture went through, kept beside it as `<file>.steps/` by the picture model that keeps a person
    /// (2026-11-08: a broken first step never reached the app, so where it went wrong could not be seen). In name order.
    public static func steps(of file: URL) -> [URL] {
        let folder = stepsFolder(of: file)
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func stepsFolder(of file: URL) -> URL { file.appendingPathExtension("steps") }

    /// The file a note names.
    public static func file(inNote text: String) -> URL? {
        guard isNote(text), let range = text.range(of: "保存先: ") else { return nil }
        let path = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// The last finished file of a kind that still exists, newest first in `contents`' order.
    public static func lastFile(_ kind: Kind, in contents: [String], exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        contents.reversed().compactMap(file(inNote:)).first { ($0.pathExtension == "mp4") == (kind == .video) && exists($0) }
    }

    /// The picture a request in the chat works on: the first when it says so, none when it starts anew, else the last.
    public static func workingPicture(for text: String, in contents: [String], exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        guard !startsAnew(text) else { return nil }
        if pointsAtFirstImage(text) {
            return contents.compactMap(file(inNote:)).first { $0.pathExtension != "mp4" && exists($0) }
        }
        return lastFile(.image, in: contents, exists: exists)
    }

    /// The kind of the last picture or video the conversation made, from its notes.
    public static func lastMadeKind(in contents: [String]) -> Kind? {
        contents.reversed().compactMap(file(inNote:)).first.map { $0.pathExtension == "mp4" ? .video : .image }
    }

    /// A model's reply that says a file was made, or names one that does not exist. Only the app can make one.
    public static func claimsUnmadeFile(_ reply: String, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Bool {
        if let file = file(inNote: reply) { return !exists(file) }
        return ["画像ができました", "動画ができました", "画像を生成しました", "動画を生成しました", "画像を作りました", "動画を作りました"]
            .contains { reply.contains($0) }
    }

    /// A chat message that asks for a picture or a video, sent while the menu says 会話. Questions about them stay in the chat.
    /// `lastMade` is the kind of the conversation's last picture or video, if it has one: a change to it or a 「生成」 that
    /// refers back asks for the same kind (2026-11-08: after a picture, 「この人物を全裸にして」 and 「さっきの条件で生成」
    /// reached the chat model, which answered that it cannot make files).
    /// `justMade`: the conversation's last message is that picture or video. Then a plain change to it (「腕を組ませて」,
    /// 「顔も写るように引いて」) asks for the same kind too (2026-11-11: it reached the chat model, which only described it).
    public static func requestedKind(_ text: String, lastMade: Kind? = nil, justMade: Bool = false) -> Kind? {
        let asking = ["教えて", "とは", "方法", "作り方", "どうやって", "できますか", "？", "?"]
        guard !asking.contains(where: text.contains) else { return nil }
        let making = ["生成", "作って", "作成", "にして", "出して", "描いて", "撮って", "作り直", "変えて", "させて"]
        let makes = making.contains(where: text.contains)
        if (["動画", "ムービー"].contains(where: text.contains) && makes)
            || ["画像を動かして", "写真を動かして", "絵を動かして", "これを動かして"].contains(where: text.contains) { return .video }
        if ["画像", "写真", "イラスト", "絵を"].contains(where: text.contains) && makes { return .image }
        if justMade, let lastMade, isChange(text) { return lastMade }
        guard makes, let lastMade else { return nil }
        if pointsAtLastImage(text) { return .image }
        if ["生成", "作り直", "もう一度", "さっきの", "同じ条件"].contains(where: text.contains) { return lastMade }
        return nil
    }

    /// A request to change something (ending in 「〜て」), not a writing task such as 「まとめて」 or 「翻訳して」.
    static func isChange(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: " 　。！!、").union(.whitespacesAndNewlines))
        let writing = ["まとめて", "教えて", "説明して", "翻訳して", "要約して", "書いて", "調べて", "答えて", "話して", "読んで", "考えて"]
        return (body.hasSuffix("て") || body.hasSuffix("ください")) && !writing.contains(where: body.contains)
    }

    /// 「この画像を動かして」: the video starts from the last picture without attaching it again.
    public static func pointsAtLastImage(_ text: String) -> Bool {
        ["この画像", "この写真", "この絵", "さっきの画像", "さっきの写真", "今の画像", "生成した画像"].contains(where: text.contains) || namesPerson(text)
    }

    /// In a chat, a picture or video request works on the last picture unless it says to start anew (2026-11-14, the user:
    /// 「チャットなんだから連続で考えられなきゃダメ。最初の画像でとか指定がない限りは、直前の画像に対しての操作とみなすべき」;
    /// 「通行人がいる東京駅の正面入り口をまっすぐ歩かせて」 had been made from words alone, with another face and clothes).
    public static func startsAnew(_ text: String) -> Bool {
        ["新しい", "新しく", "別の", "別人", "違う人", "最初から", "一から", "ゼロから", "画像なしで", "写真なしで"].contains(where: text.contains)
    }

    /// Whether a picture's prompt shows a person, so a change to it keeps that person (2026-11-14: 「場所を香港にして全裸にして」
    /// sent again after a picture of a woman went to the model that draws from words alone).
    public static func showsPerson(_ prompt: String?) -> Bool {
        guard let prompt else { return false }
        return prompt.range(of: #"\b(woman|man|girl|boy|person|lady|she|he|her|his)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 「最初の画像で」: the first picture of the chat instead of the last.
    public static func pointsAtFirstImage(_ text: String) -> Bool {
        ["最初の画像", "最初の写真", "一枚目", "1枚目", "１枚目", "最初に作った"].contains(where: text.contains)
    }

    /// Whether the request is about the same person as in the picture, not only the picture.
    public static func namesPerson(_ text: String) -> Bool {
        let pointers = ["この", "その", "画像の", "写真の", "さっきの", "同じ", "上の", "前の"]
        let people = ["人物", "女性", "男性", "人", "子", "女の人", "男の人", "モデル"]
        return pointers.contains { pointer in people.contains { text.contains(pointer + $0) } }
    }
}
