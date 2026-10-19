import Foundation
import Testing
@testable import HarnessApp

/// V1 (2026-10-19): the chosen Qwen3-TTS model (1.7B since 2026-10-19) installed through the app's own installer (pinned runtime, model revision and
/// weight checks). HARNESS_TTS_LIVE=1. Downloads about 4.5 GB into the app's voice-engine folder.
struct VoiceEngineLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TTS_LIVE"] != nil), .timeLimit(.minutes(60)))
    func installsTheChosenQwen3TTSThroughTheAppInstaller() async throws {
        let installer = Qwen3TTSMLXInstaller()
        let adapter = Qwen3TTSMLXAdapter()
        if await adapter.readiness().phase != .ready {
            if await installer.hasResumableInstallation() { try await installer.discardPartialInstallation() }
            try await installer.install { progress in
                print("導入: \(progress.phase) \(Int((progress.fraction ?? 0) * 100))% \(progress.status)")
            }
        }
        let readiness = await adapter.readiness()
        let configuration = Qwen3TTSMLXConfiguration.managed()
        print("状態: \(readiness.phase)  python=\(configuration.pythonExecutableURL.path)  worker=\(configuration.workerURL.path)  model=\(configuration.modelURL.path)")
        #expect(readiness.phase == .ready)
    }

    /// The resident speaker: loaded once, then each sentence's first piece arrives in about the measured 1.4 s.
    /// HARNESS_TTS_LIVE=<reference.wav path>|<its transcript>.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TTS_LIVE"]?.contains("|") == true), .timeLimit(.minutes(10)))
    func residentSpeakerStreamsPiecesQuickly() async throws {
        let parts = ProcessInfo.processInfo.environment["HARNESS_TTS_LIVE"]!.split(separator: "|", maxSplits: 1).map(String.init)
        let reference = try Data(contentsOf: URL(fileURLWithPath: parts[0]))
        let speaker = Qwen3TTSResidentSpeaker()
        let started = ContinuousClock.now
        try await speaker.start()
        print("起動: \(ContinuousClock.now - started)")
        for text in ["了解しました。始めます。", "ビルドが通りました。テストが二件落ちています。直しますか？",
                     "作り始める前に二点だけ確認させてください。介助者の無料券は枚数に数えませんね。"] {
            let asked = ContinuousClock.now
            var first: Duration?
            var count = 0
            try await speaker.speak(text, referenceAudio: reference, referenceText: parts[1], languageCode: "ja") { _ in
                if first == nil { first = ContinuousClock.now - asked }
                count += 1
            }
            print("「\(text.prefix(12))」 最初の音まで \(first ?? .zero) / 全体 \(ContinuousClock.now - asked) / \(count) 片")
            #expect(count > 0)
        }
        await speaker.stop()
    }
}
