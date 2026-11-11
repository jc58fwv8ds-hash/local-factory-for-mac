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
        ["この画像", "この写真", "この絵", "さっきの画像", "さっきの写真", "今の画像", "生成した画像", "この人物", "この女性", "この男性", "この人"].contains(where: text.contains)
    }
}
