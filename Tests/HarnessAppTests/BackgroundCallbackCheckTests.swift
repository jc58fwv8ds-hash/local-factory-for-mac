import Foundation
import Testing
@testable import HarnessCore

struct BackgroundCallbackCheckTests {
    @Test func findsSystemCallbacksWithoutSendable() {
        let text = """
        @MainActor final class Listener {
            func start() {
                SFSpeechRecognizer.requestAuthorization { @Sendable status in }
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                }
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in }
                // inputNode.installTap(onBus: 0) { buffer, _ in }
            }
        }
        """
        #expect(BackgroundCallbackCheck.findings(in: text) == [4, 6])
    }
}
