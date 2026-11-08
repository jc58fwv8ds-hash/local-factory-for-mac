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

    /// A model's reply that says a file was made, or names one that does not exist. Only the app can make one.
    public static func claimsUnmadeFile(_ reply: String, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Bool {
        if let file = file(inNote: reply) { return !exists(file) }
        return ["画像ができました", "動画ができました", "画像を生成しました", "動画を生成しました", "画像を作りました", "動画を作りました"]
            .contains { reply.contains($0) }
    }

    /// A chat message that asks for a picture or a video, sent while the menu says 会話. Questions about them stay in the chat.
    public static func requestedKind(_ text: String) -> Kind? {
        let asking = ["教えて", "とは", "方法", "作り方", "どうやって", "できますか", "？", "?"]
        guard !asking.contains(where: text.contains) else { return nil }
        let making = ["生成", "作って", "作成", "にして", "出して", "描いて", "撮って"]
        let makes = making.contains(where: text.contains)
        if (["動画", "ムービー"].contains(where: text.contains) && makes)
            || ["画像を動かして", "写真を動かして", "絵を動かして", "これを動かして"].contains(where: text.contains) { return .video }
        if ["画像", "写真", "イラスト", "絵を"].contains(where: text.contains) && makes { return .image }
        return nil
    }

    /// 「この画像を動かして」: the video starts from the last picture without attaching it again.
    public static func pointsAtLastImage(_ text: String) -> Bool {
        ["この画像", "この写真", "この絵", "さっきの画像", "さっきの写真", "今の画像", "生成した画像", "この人物", "この女性", "この男性", "この人"].contains(where: text.contains)
    }
}
