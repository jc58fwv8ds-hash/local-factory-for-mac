import Foundation
import Testing
@testable import HarnessCore
@testable import HarnessApp

struct ScreenshotDescriptionTests {
    @Test func linesGoTopToBottomWithTheirPlace() throws {
        func line(_ text: String, y: Double, x: Double) -> VisualRecognizedLine {
            VisualRecognizedLine(text: text, confidence: 1, bounds: VisualNormalizedRect(x: x, y: y, width: 0.2, height: 0.02))
        }
        let text = try #require(ScreenshotDescription.describe(name: "screen.png", lines: [
            line("停止", y: 0.13, x: 0.7), line("読み上げ", y: 0.85, x: 0.05), line("聞いています", y: 0.46, x: 0.4)]))
        let rows = text.components(separatedBy: "\n").dropFirst()
        #expect(rows.map { $0.components(separatedBy: ": ").last! } == ["読み上げ", "聞いています", "停止"])
        #expect(rows.first?.contains("左") == true)
        #expect(rows.last?.contains("右") == true)
    }
}

struct RequestSplittingTests {
    @Test func readsTheModelsListAndKnowsWhenToAsk() {
        #expect(RequestSplitting.parse("```json\n[\"1分で止まるのを直す\", \"字幕を日本語だけにする(画像1)\"]\n```") == ["1分で止まるのを直す", "字幕を日本語だけにする(画像1)"])
        #expect(RequestSplitting.parse("分けられませんでした") == nil)
        #expect(!RequestSplitting.mayHoldSeveral("動かないよ"))
        #expect(RequestSplitting.mayHoldSeveral("読み上げが止まる。字幕が英語だけ。画面が狭い。"))
        #expect(RequestSplitting.prompt("x", pictures: nil).contains("健在"))
    }
}

struct AutopilotQueueTests {
    @MainActor @Test func runsOneAfterAnotherAndSumsUp() {
        let requests = AutopilotRequests()
        requests.store = UserDefaults(suiteName: "queue-\(UUID().uuidString)")!
        let id = UUID()
        requests.request(all: ["一つ目", "二つ目"], projectID: id)
        #expect(requests.pending?.text == "一つ目")
        #expect(requests.hasWaiting(id))
        #expect(requests.ended(projectID: id, good: true) == nil)
        #expect(requests.pending?.text == "二つ目")
        let tally = requests.ended(projectID: id, good: false)
        #expect(tally?.total == 2 && tally?.good == 1)
        #expect(requests.unfinished(projectID: id) == ["二つ目"])   // for 「続けて」
    }
}
