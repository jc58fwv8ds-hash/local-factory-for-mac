import Foundation

/// A file asked for again after the last answer changed nothing is asked with some freedom (2026-11-17: 14Translate's
/// reading repair came back byte for byte the same five times, the nudge 「前の案はファイルを変えていませんでした」 included;
/// file writing runs at temperature 0, so the same prompt gave the same answer).
public enum WriterRetry {
    public static let marks = ["前回の案は使えませんでした", "前の案はファイルを変えていませんでした"]
    public static let retryTemperature = 0.6

    /// nil keeps the default (0 for a file); a retry after an unchanged answer gets `retryTemperature`.
    public static func temperature(for messages: [InferenceMessage]) -> Double? {
        let asked = messages.last { $0.role == .user }?.content ?? ""
        return marks.contains(where: asked.contains) ? retryTemperature : nil
    }
}
