import Foundation
@testable import HarnessCore
import Testing

struct UnfinishedCodeCheckTests {
    @Test func aStandInLeftInASavedFileIsNotAPass() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unfinished-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        try """
        func processFallbackAudio() {
            // Generate placeholder text
            let placeholderText = "[音声認識不可、代替処理中]"
            onFinalSentence?(placeholderText)
        }
        """.write(to: root.appendingPathComponent("App/Listener.swift"), atomically: true, encoding: .utf8)
        try "// TODO: old note\nlet a = 1\n".write(to: root.appendingPathComponent("App/Old.swift"), atomically: true, encoding: .utf8)
        let found = UnfinishedCodeCheck.diagnostics(rootURL: root, savedFiles: ["App/Listener.swift", "App/Old.swift"],
                                                    before: { $0 == "App/Old.swift" ? "// TODO: old note\n" : nil })
        #expect(found.count == 1)
        #expect(found.first?.relativePath == "App/Listener.swift")
        #expect(found.first?.line == 2)
        #expect(found.first?.message.contains("仮の作り") == true)
        try? FileManager.default.removeItem(at: root)
    }
}
