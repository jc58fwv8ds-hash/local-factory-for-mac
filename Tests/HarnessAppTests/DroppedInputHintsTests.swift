import Testing
@testable import HarnessCore

struct DroppedInputHintsTests {
    @Test func findsAQueueEmptiedForTheNewestInput() {
        let code = """
        final class Controller {
            func handle(_ text: String) {
                if busy {
                    task?.cancel()
                    queue.removeAll()
                }
                queue.append(text)
                process()
            }
        }
        """
        let hints = NotWorkingHints.dropsInput([("App/Controller.swift", code)])
        #expect(hints.count == 1)
        #expect(hints[0].contains(NotWorkingHints.droppedInputMark))
        #expect(hints[0].contains("handle"))
    }

    @Test func findsElapsedTimeMeasuredRightAfterReset() {
        let code = """
        func partial(_ text: String) {
            lastText = text
            lastUpdate = Date()
            let elapsed = Date().timeIntervalSince(lastUpdate) >= 1.5
            if elapsed { flush() }
        }
        """
        let hints = NotWorkingHints.dropsInput([("A.swift", code)])
        #expect(hints.count == 1)
        #expect(hints[0].contains(NotWorkingHints.zeroElapsedMark))
    }

    @Test func leavesCorrectCodeAlone() {
        let code = """
        func partial(_ text: String) {
            let elapsed = Date().timeIntervalSince(lastUpdate) >= 1.5
            lastUpdate = Date()
            queue.append(text)
        }
        func run() {
            let startTime = Date()
            while true {
                if Date().timeIntervalSince(startTime) > 10 { break }
            }
        }
        func empty(_ text: String) {
            if text.isEmpty {
                lastUpdate = Date()
                return
            }
            let waited = Date().timeIntervalSince(lastUpdate) >= 1.5
            lastUpdate = Date()
        }
        func reset() {
            queue.removeAll()
        }
        """
        #expect(NotWorkingHints.dropsInput([("A.swift", code)]).isEmpty)
    }
}
