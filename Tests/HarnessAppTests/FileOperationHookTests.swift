import Foundation
import Testing
@testable import HarnessApp

struct FileOperationHookTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("file-ops-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func file(_ name: String) -> URL {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }

    @Test func anEditNeverWritesOverTheOriginalOrAnExistingFile() throws {
        let original = file("売上.xlsx"), existing = file("売上_編集済み.xlsx")
        let guardHook = OriginalProtectionHook()
        #expect(throws: OriginalProtectionHook.Refusal.overwritesOriginal("売上.xlsx")) {
            try guardHook.before(.init(kind: .excel, action: .write, instruction: "", reads: [original], writes: [original]))
        }
        #expect(throws: OriginalProtectionHook.Refusal.exists("売上_編集済み.xlsx")) {
            try guardHook.before(.init(kind: .excel, action: .write, instruction: "", reads: [original], writes: [existing]))
        }
        try guardHook.before(.init(kind: .excel, action: .write, instruction: "", reads: [original],
                                   writes: [folder.appendingPathComponent("売上_編集済み 2.xlsx")]))
    }

    @Test func undoOnlyTrashesFilesTheAppWrote() throws {
        let original = file("案内.docx"), written = file("案内_編集済み.docx")
        let guardHook = OriginalProtectionHook()
        #expect(throws: OriginalProtectionHook.Refusal.notWrittenByApp("案内.docx")) {
            try guardHook.before(.init(kind: .word, action: .revert, instruction: "", reads: [original], writes: [original]))
        }
        try guardHook.before(.init(kind: .word, action: .revert, instruction: "", reads: [original], writes: [written]))
    }

    @Test func aRenameMaySwapNamesInsideThePlanButNotLandOnAnotherFile() throws {
        let a = file("a.txt"), b = file("b.txt"), other = file("c.txt")
        let guardHook = OriginalProtectionHook()
        try guardHook.before(.init(kind: .rename, action: .write, instruction: "", reads: [a, b], writes: [b, a]))
        #expect(throws: OriginalProtectionHook.Refusal.exists("c.txt")) {
            try guardHook.before(.init(kind: .rename, action: .write, instruction: "", reads: [a], writes: [other]))
        }
    }

    @Test func aRefusedOperationDoesNotRunAndIsJournaledAsStopped() throws {
        let original = file("資料.pdf")
        let journal = FileOperationJournal(folder: folder.appendingPathComponent("journal"))
        var ran = false
        #expect(throws: (any Error).self) {
            try FileOperationRunner.perform(.init(kind: .pdf, action: .write, instruction: "3ページ目を外して", reads: [original],
                                                  writes: [original]), hooks: [OriginalProtectionHook(), journal]) { ran = true }
        }
        try FileOperationRunner.perform(.init(kind: .pdf, action: .write, instruction: "回転して", reads: [original],
                                              writes: [folder.appendingPathComponent("資料_編集済み.pdf")]), hooks: [journal]) {}
        #expect(!ran)
        let logs = try FileManager.default.contentsOfDirectory(at: journal.folder, includingPropertiesForKeys: nil)
        let lines = try String(contentsOf: logs[0], encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        #expect(lines.map { $0["outcome"] as? String } == ["stopped", "done"])
        #expect(lines[0]["instruction"] as? String == "3ページ目を外して" && lines[0]["error"] != nil)
    }
}
