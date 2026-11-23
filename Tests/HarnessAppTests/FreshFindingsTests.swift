import Foundation
import Testing
@testable import HarnessApp

struct FreshFindingsTests {
    @Test func aKeptRequestGetsWhatTheCodeShowsNow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        final class Speaker {
            func speak(_ text: String) {
                queue.append(text)
            }
            func stopNow() {
                synthesizer?.stopSpeaking(at: .immediate)
            }
        }
        final class Controller {
            func startSpeaking(_ text: String) {
                speaker.stopNow()
                speaker.speak(text)
            }
        }
        """.write(to: root.appendingPathComponent("App/App.swift"), atomically: true, encoding: .utf8)
        let kept = "読み上げが途中で切れる\\n\\n調べてわかったこと:\\n古い手がかり"
        let fresh = try #require(AutopilotPurpose.freshFindings(kept, root: root.path))
        #expect(fresh.contains("行を消すだけ"))
        #expect(AutopilotPurpose.freshFindings("読み上げが途中で切れる", root: root.path) == nil)
    }
}
