import HarnessCore
import Testing
@testable import HarnessApp

struct AutopilotPurposeTests {
    @Test func everyRequestCarriesWhatTheAppIsFor() {
        let text = AutopilotPurpose.instruction("読み上げが数十秒遅れる", summary: "英語を日本語に訳して読み上げるリアルタイム翻訳アプリ")
        #expect(text.hasPrefix("読み上げが数十秒遅れる"))
        #expect(text.contains("リアルタイム翻訳アプリ"))
        #expect(AutopilotPurpose.instruction("直して", summary: "  ") == "直して")
    }
}

struct OwnAsksTests {
    @Test func aPictureDescriptionIsNotARequest() {
        let text = "停止すると必ずエラーが出る。読み上げが数十秒遅れる"
        let items = ["停止すると必ずエラーが出る", "読み上げが数十秒遅れる",
                     "画面写真について読み取ったこと: " + String(repeating: "上部に「翻訳」の大きな文字。", count: 10)]
        #expect(RequestSplitting.ownAsks(items, in: text) == ["停止すると必ずエラーが出る", "読み上げが数十秒遅れる"])
        #expect(RequestSplitting.ownAsks([items[2]], in: text) == [text])
    }
}
