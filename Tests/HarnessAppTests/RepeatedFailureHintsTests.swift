import Foundation
@testable import HarnessCore
import Testing

struct RepeatedFailureHintsTests {
    // 2026-11-16: every sentence 14Translate heard was thrown away by its own check, and nothing crashed.
    @Test func theSameFailureEveryTimePointsAtTheCheckThatDecidesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repeat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        try """
        actor PlamoTranslator {
            func translate(_ text: String) -> [String] {
                var translated = text
                if isInvalidTranslation(original: text, translated: translated) {
                    print("[PlamoTranslator] 翻訳結果が不適切です。再翻訳を試行中...")
                }
                return [translated]
            }

            private func isInvalidTranslation(original: String, translated: String) -> Bool {
                let words = original.components(separatedBy: " ")
                for word in words where !translated.contains(word) { return true }
                return false
            }
        }
        """.write(to: root.appendingPathComponent("App/PlamoTranslator.swift"), atomically: true, encoding: .utf8)
        let console = [
            "[PlamoTranslator] 翻訳開始: That's a question...",
            "[PlamoTranslator] 翻訳結果が不適切です。再翻訳を試行中...",
            "[PlamoTranslator] 翻訳開始: Explain the...",
            "[PlamoTranslator] 翻訳結果が不適切です。再翻訳を試行中...",
            "[PlamoTranslator] 翻訳開始: Explain the legal...",
            "[PlamoTranslator] 翻訳結果が不適切です。再翻訳を試行中..."
        ]
        let hints = NotWorkingHints.repeatedFailures(console, rootURL: root)
        let hint = try #require(hints.first)
        #expect(hint.contains("3 回"))
        #expect(hint.contains("App/PlamoTranslator.swift の func translate(…)"))
        #expect(hint.contains("if isInvalidTranslation(original: text, translated: translated)"))
        #expect(hint.contains("for word in words where !translated.contains(word)"))
        #expect(NotWorkingHints.plain(hints).first?.contains("正しい結果まではじいている") == true)
        // Failures that do not repeat, and lines that are not failures, say nothing.
        #expect(NotWorkingHints.repeatedFailures(Array(console.prefix(4)), rootURL: root).isEmpty)
        #expect(NotWorkingHints.failureMessage("[TranslationController] Translation started") == nil)
        try? FileManager.default.removeItem(at: root)
    }
}

struct ListensForOneQueryTests {
    @Test func aSearchHintForContinuousListeningIsFound() {
        let code = "let request = SFSpeechAudioBufferRecognitionRequest()\nrequest.taskHint = .search"
        let hints = NotWorkingHints.listensForOneQuery([("App/SpeechListener.swift", code)])
        #expect(hints.first?.contains("taskHint = .dictation") == true)
        #expect(NotWorkingHints.plain(hints).first?.contains("最初の数語") == true)
        #expect(NotWorkingHints.listensForOneQuery([("App/S.swift", code.replacingOccurrences(of: ".search", with: ".dictation"))]).isEmpty)
    }
}

struct OptionalBindingAdviceTests {
    @Test func ifLetOnAPlainStringGetsAWayToRewriteIt() {
        let advice = BuildErrorAdvice.lines(for: ["initializer for conditional binding must have Optional type, not 'String'"])
        #expect(advice.first?.contains("!値.isEmpty") == true)
    }
}

struct GrowingPiecesTests {
    @Test func eachLongerPieceHandledAgainIsFound() {
        let console = [
            "[TranslationController] Transcript received: They don't give anything",
            "[PlamoTranslator] 翻訳開始: They don't give anything...",
            "[TranslationController] Transcript received: They don't give anything to",
            "[TranslationController] Transcript received: They don't give anything to people like",
            "[TranslationController] Transcript received: They don't give anything to people like me",
            "[TranslationController] Transcript received: Camino"
        ]
        let hints = NotWorkingHints.growingPieces(console)
        #expect(hints.first?.contains("「They don't give anything」→ … →「They don't give anything to people like me」") == true)
        #expect(NotWorkingHints.plain(hints).first?.contains("頭から訳し直して") == true)
        #expect(NotWorkingHints.growingPieces(["[A] Transcript received: Hello", "[A] Transcript received: Camino"]).isEmpty)
    }
}
