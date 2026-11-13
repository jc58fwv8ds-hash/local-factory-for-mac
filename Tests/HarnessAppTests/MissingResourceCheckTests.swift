import Foundation
import Testing
@testable import HarnessCore

struct MissingResourceCheckTests {
    @Test func namesModelFilesInLiteralsAndResourcePairs() {
        #expect(MissingResourceCheck.namedFiles(in: #"let fileName = "plamo-7b-q4_k_m.gguf""#) == ["plamo-7b-q4_k_m.gguf"])
        #expect(MissingResourceCheck.namedFiles(in: #"Bundle.main.url(forResource: "model", withExtension: "gguf")"#) == ["model.gguf"])
        #expect(MissingResourceCheck.namedFiles(in: #"let icon = "AppIcon.png""#).isEmpty)
    }

    @Test func reportsAMissingModelWithTheOneThatExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("missing-resource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App/Models"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("App/Models/plamo-3-translate-0.8b-Q4_K_M.gguf"))
        try #"let a = "plamo-7b-q4_k_m.gguf"\nlet b = "plamo-3-translate-0.8b-Q4_K_M.gguf""#
            .replacingOccurrences(of: "\\n", with: "\n").write(to: root.appendingPathComponent("App/Controller.swift"), atomically: true, encoding: .utf8)
        let found = MissingResourceCheck.diagnostics(rootURL: root)
        #expect(found.count == 1)
        #expect(found.first?.relativePath == "App/Controller.swift")
        #expect(found.first?.line == 1)
        #expect(found.first?.message.contains("「plamo-3-translate-0.8b-Q4_K_M.gguf」") == true)
    }
}

@testable import HarnessApp

struct DeviceChatIntentTests {
    @Test func installRequestsGoToTheDevice() {
        #expect(CodeChatIntent.asksForDevice("iPhone に入れて"))
        #expect(CodeChatIntent.asksForDevice("実機で動かして"))
        #expect(CodeChatIntent.asksForDevice("iPhoneで試したい"))
        #expect(!CodeChatIntent.asksForDevice("iPhone の画面に字幕を追加して"))
        #expect(!CodeChatIntent.asksForDevice("録音機能を入れて"))
        #expect(CodeChatIntent.asksForWork("翻訳が表示されないことが問題。日本語だけで良いのでは？"))
        #expect(!CodeChatIntent.asksForWork("この関数は何をしているの？"))
        #expect(CodeChatIntent.mentionsNotWorking("新しいバージョンもダメだね。全く読み上げも翻訳も開始しない。繋いでないのと一緒"))
        #expect(CodeChatIntent.mentionsNotWorking("保存されない"))
        #expect(CodeChatIntent.mentionsNotWorking("読み上げは行われているが、開始の速度が遅く結果分の抜けもある。"))
        #expect(!CodeChatIntent.mentionsNotWorking("なぜ遅いの？"))
        #expect(CodeChatIntent.mentionsNotWorking("日本語として破綻している"))
        #expect(!CodeChatIntent.mentionsNotWorking("翻訳を開始したらどうなるの？"))
    }

    @Test func trustFailureAsksForTheIPhoneStep() {
        #expect(DeviceChatWords.failure("The profile has not been explicitly trusted by the user.").contains("VPN とデバイス管理"))
        #expect(DeviceChatWords.failure("other").hasPrefix("iPhone に入れられませんでした"))
    }
}
