import Foundation

/// A crash report (.ips) of an app on the iPhone, read for what a person or the model needs to fix it (2026-11-11: 14Translate
/// quit a little after it opened on the iPhone; the user can only say 「落ちる」, and the reason was in the iPhone's report:
/// SpeechListener.start()'s permission callback, made on a background queue, ran as main-actor code).
public struct DeviceCrashReport: Equatable, Sendable {
    public let exception: String
    /// The app's own frames, innermost first (symbols such as "closure #1 in SpeechListener.start()").
    public let appFrames: [String]
    /// The system's reason, when it gave one (a missing library, a memory limit).
    public let reasons: [String]
    /// The top frames whatever their image, innermost first.
    public let topFrames: [String]

    public init(exception: String, appFrames: [String], reasons: [String], topFrames: [String]) {
        self.exception = exception
        self.appFrames = appFrames
        self.reasons = reasons
        self.topFrames = topFrames
    }

    /// Reads an .ips file: a one-line header, then the report as JSON. `appName` is the app's executable name.
    public static func parse(_ text: String, appName: String) -> DeviceCrashReport? {
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2, let data = parts[1].data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let exception = body["exception"] as? [String: Any]
        let termination = body["termination"] as? [String: Any]
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        let frames = (threads.first { ($0["triggered"] as? Bool) == true }?["frames"] as? [[String: Any]]) ?? []
        func image(_ frame: [String: Any]) -> String {
            (frame["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? ""
        }
        let symbols = frames.map { (image($0), ($0["symbol"] as? String) ?? "?") }
        let own = symbols.filter { $0.0 == appName || $0.0.hasPrefix(appName + ".") }.map(\.1)
        let kind = [exception?["type"] as? String, exception?["signal"] as? String].compactMap { $0 }.joined(separator: " ")
        return DeviceCrashReport(exception: kind.isEmpty ? ((termination?["indicator"] as? String) ?? "不明") : kind,
                                 appFrames: own, reasons: (termination?["reasons"] as? [String]) ?? [],
                                 topFrames: symbols.prefix(6).map(\.1))
    }

    /// The type the innermost app frame belongs to: 「closure #1 in SpeechListener.start()」 → SpeechListener.
    public var typeName: String? {
        guard let frame = appFrames.first else { return nil }
        let tail = frame.components(separatedBy: " in ").last ?? frame
        let name = tail.split(separator: "(").first.map(String.init) ?? tail
        let parts = name.split(separator: ".").map(String.init)
        return parts.count >= 2 ? parts[parts.count - 2] : nil
    }

    /// For the person, in everyday words (2026-11-11, the user: 「落ちた記録とかの記載の発想は一般ユーザーにはないよ」):
    /// where in the app's work it stopped, without the report's terms. The details go only to the model.
    public var plainSummary: String {
        let frames = (appFrames + topFrames).joined(separator: " ")
        let moment = frames.contains("Authorization") || frames.contains("TCCAccess") ? "マイクや音声認識を使ってよいかの返事を受け取るところ"
            : frames.contains("Speech") ? "声を聞き取るところ"
            : frames.contains("Synthes") || frames.contains("Speaker") ? "読み上げるところ"
            : frames.contains("Audio") || frames.contains("Record") ? "音を扱うところ"
            : reasons.contains(where: { $0.contains("Library not loaded") }) ? "アプリを開くところ"
            : "動いている途中"
        return "アプリは\(moment)で止まっていました。"
    }

    /// What went wrong and how to fix it, in plain words for the repair instruction.
    public var advice: String {
        var lines = ["iPhone で落ちた記録: \(exception)。"]
        if let frame = appFrames.first { lines.append("落ちた場所(アプリのコード): \(frame)") }
        if appFrames.count > 1 { lines.append("そこを呼んだ場所: " + appFrames.dropFirst().prefix(3).joined(separator: " ← ")) }
        lines += reasons.prefix(2).map { "理由: " + $0 }
        let top = topFrames.joined(separator: " ")
        if top.contains("dispatch_assert_queue") || top.contains("swift_task_isCurrentExecutor") || top.contains("checkIsolated") {
            lines.append("原因: システムが背景のスレッドから呼ぶクロージャ(許可の返事、音声認識や録音の結果など)が、@MainActor の型の中に書かれて main actor のものと見なされ、実行時の確認で落ちています。"
                + "直し方: そのクロージャを `{ @Sendable value in ... }` のように main actor から切り離し、self やプロパティに触る処理は中で `Task { @MainActor in ... }` に包む。"
                + "または requestAuthorization などを `await withCheckedContinuation` で包んで async にする。")
        } else if reasons.contains(where: { $0.contains("Library not loaded") }) {
            lines.append("原因: アプリに入れた部品(framework)を iPhone で読み込めていません。")
        } else if exception.contains("EXC_BAD_ACCESS") {
            lines.append("原因: 解放済みや範囲外のメモリに触っています(C の部品へのポインタの扱いを確かめてください)。")
        } else if top.contains("swift_unexpectedError") || top.contains("fatalError") || top.contains("_assertionFailure") {
            lines.append("原因: try! や強制アンラップ(!)、fatalError で止まっています。失敗しても落ちないように扱ってください。")
        }
        return lines.joined(separator: "\n")
    }
}
