import Testing
@testable import HarnessCore

struct StreamGapHintsTests {
    @Test func findsAWaitThatDropsItsFraction() {
        let code = "try? await Task.sleep(nanoseconds: UInt64(self?.silenceTimeout ?? 0.8) * 1_000_000_000)"
        #expect(NotWorkingHints.streamGaps([("A.swift", code)]).first?.contains(NotWorkingHints.truncatedWaitMark) == true)
        #expect(NotWorkingHints.streamGaps([("A.swift", "try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))")]).isEmpty)
    }

    @Test func findsPartialAndFinalTextSentToTheSameTranslation() {
        let code = """
        init() {
            listener.onFinalSentence = { [weak self] text in
                self?.handleTranscript(text)
            }
            listener.$partialText
                .sink { [weak self] text in
                    self?.handlePartial(text)
                }
        }
        func handlePartial(_ text: String) {
            if text.count > 20 { handleTranscript(text) }
        }
        func handleTranscript(_ text: String) {
            queue.append(text)
        }
        """
        let hints = NotWorkingHints.streamGaps([("C.swift", code)])
        #expect(hints.count == 1)
        #expect(hints[0].contains("handleTranscript"))
        #expect(hints[0].contains("handlePartial の中"))
        #expect(hints[0].contains("呼び出しそのものをやめる"))
    }

    @Test func findsASpeechAnalyzerRestartedAfterEverySentence() {
        let code = """
        var analyzer: SpeechAnalyzer?
        var transcriber: SpeechTranscriber?
        func processFinalText(_ text: String) {
            onFinalSentence?(text)
            restartRecognition()
        }
        """
        #expect(NotWorkingHints.streamGaps([("L.swift", code)]).first?.contains(NotWorkingHints.restartGapMark) == true)
        let onlyFallback = code.replacingOccurrences(of: "    restartRecognition()", with: "    if mode == .fallback {\n        restartRecognition()\n    }")
        #expect(NotWorkingHints.streamGaps([("L.swift", onlyFallback)]).isEmpty)
    }

    @Test func findsMicrophoneBuffersGivenToTheAnalyzerAsTheyCome() {
        let raw = "input.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { buffer, _ in continuation.yield(AnalyzerInput(buffer: buffer)) }"
        #expect(NotWorkingHints.streamGaps([("L.swift", raw)]).first?.contains(NotWorkingHints.analyzerFormatMark) == true)
        let converted = raw + "\nlet format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])\nlet c = AVAudioConverter(from: micFormat, to: format!)"
        #expect(NotWorkingHints.streamGaps([("L.swift", converted)]).isEmpty)
    }

    @Test func findsAConverterFedTheSameBufferIntoAFixedSize() {
        let bad = """
        let frameCapacity = AVAudioFrameCount(targetFormat.sampleRate) * 1024 / AVAudioFrameCount(recordingFormat.sampleRate)
        let status = audioConverter.convert(to: convertedBuffer, error: &error) { _, _ in
            return buffer
        }
        """
        let hint = NotWorkingHints.streamGaps([("L.swift", bad)]).first ?? ""
        #expect(hint.contains("outStatus.pointee = .noDataNow"))
        #expect(hint.contains("buffer.frameLength"))
        let good = """
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        var given = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if given { outStatus.pointee = .noDataNow; return nil }
            given = true; outStatus.pointee = .haveData; return buffer
        }
        """
        #expect(NotWorkingHints.streamGaps([("L.swift", good)]).isEmpty)
    }
}
