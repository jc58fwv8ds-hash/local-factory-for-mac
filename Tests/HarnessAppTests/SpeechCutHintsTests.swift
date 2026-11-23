import Testing
@testable import HarnessCore

struct SpeechCutHintsTests {
    let speaker = """
    final class Speaker {
        func speak(_ text: String) {
            if queue.count >= maxQueued {
                queue.removeFirst()
                droppedCount += 1
            }
            queue.append(text)
        }
        func stopNow() {
            synthesizer?.stopSpeaking(at: .immediate)
            queue.removeAll()
        }
    }
    """

    @Test func findsSpeechStoppedBeforeEachNewPiece() {
        let controller = """
        final class Controller {
            private func startSpeaking(_ text: String) {
                isSpeaking = true
                speaker.stopNow()
                task = Task { speaker.speak(text) }
            }
            func stop() {
                speaker.stopNow()
            }
        }
        """
        let hints = NotWorkingHints.speechCuts([("App/Speaker.swift", speaker), ("App/Controller.swift", controller)])
        #expect(hints.contains { $0.contains(NotWorkingHints.cutsSpeechMark) && $0.contains("startSpeaking") && $0.contains("行を消すだけ") })
        #expect(hints.contains { $0.contains(NotWorkingHints.capsQueueMark) && $0.contains("queue") })
        #expect(!hints.contains { $0.contains("の stop は") })
    }

    @Test func queuedSpeechIsNotFlagged() {
        let controller = """
        final class Controller {
            func say(_ text: String) {
                speaker.speak(text)
            }
            func stop() {
                speaker.stopNow()
            }
        }
        """
        let calm = """
        final class Speaker {
            func speak(_ text: String) { queue.append(text) }
            func stopNow() { synthesizer?.stopSpeaking(at: .immediate) }
        }
        """
        #expect(NotWorkingHints.speechCuts([("A.swift", calm), ("B.swift", controller)]).isEmpty)
    }
}
