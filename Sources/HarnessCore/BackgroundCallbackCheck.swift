import Foundation

/// Closures the system calls from a background thread, written inside main-actor code without @Sendable: they build and
/// pass in the simulator's tests but stop the app on the iPhone (2026-11-11: 14Translate's SpeechListener — first the
/// permission reply, and the microphone tap and recognition results were written the same way). Found after a passing
/// build, the autopilot fixes them like build errors.
public enum BackgroundCallbackCheck {
    static let calls = ["requestAuthorization", "installTap(", "recognitionTask(with:", "requestRecordPermission",
                        "requestAccess(for", "setNotificationCategories", "requestPermission"]

    public static func diagnostics(rootURL: URL) -> [BuildFailureDiagnostic] {
        TestFailureAnalyzer.swiftFiles(under: rootURL).filter { !$0.contains("Tests/") }.flatMap { path -> [BuildFailureDiagnostic] in
            guard let text = try? String(contentsOf: rootURL.appendingPathComponent(path), encoding: .utf8),
                  text.contains("@MainActor") else { return [] }
            return findings(in: text).map { line in
                BuildFailureDiagnostic(validationKind: .build, relativePath: path, line: line, column: nil, message: message)
            }
        }
    }

    /// 1-based lines whose call takes a closure the system runs on a background thread, without @Sendable.
    static func findings(in text: String) -> [Int] {
        let lines = text.components(separatedBy: "\n")
        return lines.indices.filter { index in
            let line = lines[index]
            guard calls.contains(where: line.contains), !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return false }
            // The closure opens on this line or the next one.
            let opening = [line, index + 1 < lines.count ? lines[index + 1] : ""].first { $0.contains("{") }
            guard let opening, let brace = opening.range(of: "{") else { return false }
            return !opening[brace.upperBound...].contains("@Sendable")
        }.map { $0 + 1 }
    }

    static let message = "この行のクロージャは、システムが背景のスレッドから呼びます。@MainActor のコードの中にそのまま書くと、ビルドとシミュレータのテストは通っても、iPhone で動かしたときにアプリが落ちます。"
        + "`{ @Sendable [weak self] buffer, _ in` のように @Sendable を付けて main actor から切り離し、self やプロパティに触る所は中で `Task { @MainActor in ... }` に包んでください。"
        + "マイクの音(buffer)を渡すときは、Task に入れずにその場で使える形(例: 認識のリクエストを nonisolated(unsafe) の変数に持つ)にしてください。"
}
