import Foundation
import HarnessCore
import Testing

struct AppleAppProductNameTests {
    @Test func spellsALeadingNumber() {
        #expect(AppleAppProductName.suggested(from: "14Translate") == "FourteenTranslate")
        #expect(AppleAppProductName.suggested(from: "3D Viewer") == "ThreeDViewer")
        #expect(AppleAppProductName.suggested(from: "120 Days") == "OneHundredTwentyDays")
    }

    @Test func joinsWordsAndDropsSymbols() {
        #expect(AppleAppProductName.suggested(from: "my memo app!") == "MyMemoApp")
        #expect(AppleAppProductName.suggested(from: "Local-Factory 2") == "LocalFactory2")
    }

    @Test func alwaysGivesAValidName() {
        for name in ["", "翻訳", "1", "a", String(repeating: "x", count: 60), "99999Go"] {
            let product = AppleAppProductName.suggested(from: name)
            #expect(product.range(of: #"^[A-Za-z][A-Za-z0-9]{2,39}$"#, options: .regularExpression) != nil, "\(name) -> \(product)")
        }
    }
}

@testable import HarnessApp

struct CodeChatIntentTests {
    @Test func requestsAreBuiltAndQuestionsAreAnswered() {
        #expect(!CodeChatIntent.isQuestion("翻訳の画面を作って"))
        #expect(!CodeChatIntent.isQuestion("AirPods が外れたら止まるように直して"))
        #expect(CodeChatIntent.isQuestion("このアプリのしくみを教えて"))
        #expect(CodeChatIntent.isQuestion("どうしてビルドが遅いの？"))
        #expect(!CodeChatIntent.isQuestion("ボタンを追加してくれる？"))
        #expect(CodeChatIntent.isQuestion("今の返答を難しい言葉なしで言い直して。まだファイルは変えないでね"))
        #expect(CodeChatIntent.isContinue("続けて") && CodeChatIntent.isContinue("進めよう。"))
        #expect(!CodeChatIntent.isContinue("続けて画面も作って"))
    }
}

struct EmptyTestDetectionTests {
    @Test @MainActor func aTestFileWithoutExpectationsIsNotAPass() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("AppTests"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "final class T: XCTestCase { override func setUp() { super.setUp() } }"
            .write(to: root.appendingPathComponent("AppTests/EmptyTests.swift"), atomically: true, encoding: .utf8)
        try "final class U: XCTestCase { func testA() { XCTAssertEqual(1, 1) } }"
            .write(to: root.appendingPathComponent("AppTests/RealTests.swift"), atomically: true, encoding: .utf8)
        #expect(FileChangeAutopilot.emptyTests(["AppTests/EmptyTests.swift", "AppTests/RealTests.swift", "App/A.swift"],
                                               root: root.path) == ["AppTests/EmptyTests.swift"])
    }
}
