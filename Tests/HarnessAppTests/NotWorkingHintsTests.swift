import Foundation
import Testing
@testable import HarnessCore

struct NotWorkingHintsTests {
    @Test func findsUnconnectedValuesSilentErrorsAndTheFinalResultTrap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("not-working-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        final class Listener: ObservableObject {
            @Published var partialText: String = ""
            @Published var isListening = false
            func start() {
                task = recognizer.recognitionTask(with: request) { result, error in
                    if result?.isFinal == true { }
                    if localError != nil {
                        self.stop()
                    }
                }
            }
        }
        """.write(to: root.appendingPathComponent("App/Listener.swift"), atomically: true, encoding: .utf8)
        try "struct Screen { func body() { _ = listener.isListening } }".write(to: root.appendingPathComponent("App/Screen.swift"), atomically: true, encoding: .utf8)
        let hints = NotWorkingHints.hints(rootURL: root)
        #expect(hints.contains { $0.contains("Listener.partialText") })
        #expect(!hints.contains { $0.contains("isListening") })
        #expect(hints.contains { $0.contains("7 行目") })
        #expect(hints.contains { $0.contains("isFinal") })
        #expect(hints.contains { $0.contains("約 1 分で打ち切られ") })
        #expect(NotWorkingHints.plain(hints).contains { $0.hasPrefix("聞き取った文字や訳などの中身が") })
        #expect(NotWorkingHints.plain(hints).allSatisfy { !$0.contains("isFinal") && !$0.contains(".swift") })
    }

    @Test func findsAWatcherThatStopsEverythingOnAReportedError() {
        let controller = """
        speechListener.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorMessage in
                if let message = errorMessage, !message.isEmpty {
                    self?.statusText = "エラー: \\(message)"
                    if self?.isRunning == true {
                        self?.isRunning = false
                        self?.speechListener.stop()
                    }
                }
            }
        """
        let hints = NotWorkingHints.stopsOnReportedError([("App/TranslationController.swift", controller)])
        #expect(hints.count == 1)
        #expect(NotWorkingHints.plain(hints).first?.contains("開始してもすぐ止まります") == true)
        let shownOnly = controller.replacingOccurrences(of: "self?.speechListener.stop()", with: "")
            .replacingOccurrences(of: "self?.isRunning = false", with: "")
        #expect(NotWorkingHints.stopsOnReportedError([("App/TranslationController.swift", shownOnly)]).isEmpty)
    }

    @Test func findsSentencesThatEndOnlyOnSilence() {
        let listener = "task = recognizer.recognitionTask(with: request) { r, e in }\nTask { try? await Task.sleep(nanoseconds: 1_000_000_000) }"
        let hints = NotWorkingHints.knownTraps([("App/SpeechListener.swift", listener)])
        #expect(hints.contains { $0.contains("区切りが来ず") })
        #expect(NotWorkingHints.plain(hints).contains { $0.contains("音が止まるまで") })
        let capped = listener + "\nlet maxWords = 14"
        #expect(!NotWorkingHints.knownTraps([("App/SpeechListener.swift", capped)]).contains { $0.contains("区切りが来ず") })
    }

    @Test func asksForATraceWhenTheAppWritesNothing() {
        let quiet = [("App/A.swift", "struct A {}"), ("App/B.swift", "struct B {}"), ("App/C.swift", "struct C {}")]
        #expect(NotWorkingHints.untraced(quiet).count == 1)
        let traced = quiet.map { ($0.0, $0.1 + "\nprint(\"[A] start\")") }
        #expect(NotWorkingHints.untraced(traced).isEmpty)
    }

    @Test func keepsTheReadingTrapForReportsAboutReadingAndDropsFixedOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "let voice = AVSpeechSynthesisVoice(language: \"ja-JP\")".write(to: root.appendingPathComponent("App/Speaker.swift"), atomically: true, encoding: .utf8)
        #expect(!NotWorkingHints.hints(rootURL: root, request: "全く何にも聞こえない").contains { $0.contains("助数詞") })
        #expect(NotWorkingHints.hints(rootURL: root, request: "2頭を読み間違える").contains { $0.contains("助数詞") })
        let handled = "task = recognizer.recognitionTask(with: r) { _, _ in }\nif code == 1110 { restart() } else { stop() }"
        #expect(!NotWorkingHints.knownTraps([("App/L.swift", handled)]).contains { $0.contains("約 1 分で打ち切られ") })
    }

    @Test func consoleTailSkipsLibraryChatterAndSaysWhenTheAppClosed() throws {
        let root = "/tmp/console-tail-\(UUID().uuidString)"
        let file = DeviceConsoleLog.url(projectRoot: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        [now] 開きました
        [SpeechListener] started
        llama_graph_n_input_tensors: input tensor 'inp_pos' is used by node 'node_10' (ROPE)
        create_tensor: loading tensor blk.0.attn_norm.weight
        sched_reserve: MTL0 compute buffer size = 230.02 MiB
        Launched application with x bundle identifier.
        The app terminated with the exit code 0.
        """.write(to: file, atomically: true, encoding: .utf8)
        let tail = DeviceConsoleLog.tail(projectRoot: root)
        #expect(tail == ["[now] 開きました", "[SpeechListener] started", DeviceConsoleLog.closedNote])
    }

    @Test func findsARecognizerRestartedEveryFewFramesAndARecordOfNoSpeech() {
        let listener = """
        private let maxBufferedFramesThreshold = 2000
        inputNode.installTap(onBus: 0, bufferSize: 512, format: f) { buffer, _ in
            if self.bufferedFrameCount > self.maxBufferedFramesThreshold { self.restartRecognition() }
        }
        """
        let hints = NotWorkingHints.knownTraps([("App/SpeechListener.swift", listener)])
        #expect(hints.contains { $0.contains("2000 フレームごとに認識を始め直して") })
        #expect(NotWorkingHints.plain(hints).contains { $0.contains("一語も聞き取れず") })
        let calm = listener.replacingOccurrences(of: "2000", with: "2_880_000")
        #expect(!NotWorkingHints.knownTraps([("App/SpeechListener.swift", calm)]).contains { $0.contains("フレームごと") })
        let record = Array(repeating: "[SpeechListener] Ignoring error (1110) and restarting recognition", count: 7)
        #expect(NotWorkingHints.fromConsole(record).first?.contains("7 回") == true)
        #expect(NotWorkingHints.plain(NotWorkingHints.fromConsole(record)).first?.contains("届いていません") == true)
        #expect(NotWorkingHints.fromConsole(["[SpeechListener] Listening started"]).isEmpty)
    }

    @Test func leavesCatchesThatRethrowAndTranslatorsAlreadyOneAtATime() {
        let listener = "do {\n    try engine.start()\n} catch {\n    tap.remove()\n    request = nil\n    task = nil\n    cleanup()\n    throw error\n}"
        #expect(NotWorkingHints.silentErrors([("App/L.swift", listener)]).isEmpty)
        let dropped = "do {\n    try engine.start()\n} catch {\n    request = nil\n}"
        #expect(NotWorkingHints.silentErrors([("App/L.swift", dropped)]).count == 1)
        let translator = "actor T { var recent: [String] = []; func f() { llama_decode(c, b); p.n_ctx = 2048; recent.removeFirst() } }"
        #expect(!NotWorkingHints.knownTraps([("App/T.swift", translator)]).contains { $0.contains("llama_decode") })
    }
}
