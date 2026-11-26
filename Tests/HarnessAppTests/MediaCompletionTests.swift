import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

/// 2026-11-25 review: a media tool's exit was never looked at, an old file at the output passed for a new one, and a
/// picture that failed its check three times was kept and shown as done.
struct MediaCompletionTests {
    @Test func aToolThatEndsWithAnErrorIsNotASuccess() async throws {
        let output = try await ImageGenerationService.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo made; exit 0"], limit: 30)
        #expect(output.contains("made"))
        do {
            _ = try await ImageGenerationService.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo half; exit 3"], limit: 30)
            Issue.record("exit 3 was taken as a success")
        } catch let ImageGenerationService.Failure.exited(code, log) {
            #expect(code == ImageGenerationService.partialExitCode)
            #expect(log.contains("half"))
        }
        do {
            _ = try await ImageGenerationService.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "kill -9 $$"], limit: 30)
            Issue.record("a killed tool was taken as a success")
        } catch ImageGenerationService.Failure.exited { }
        #expect(ImageGenerationService.succeeded(status: 0, reason: .exit))
        #expect(!ImageGenerationService.succeeded(status: 1, reason: .exit))
        #expect(!ImageGenerationService.succeeded(status: 15, reason: .uncaughtSignal))
    }

    @Test func anEarlierFileAtTheOutputIsNotThisRunsResult() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("media-completion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("picture.png")
        #expect(!ImageGenerationService.madeAnew(output, before: nil))
        try Data("old".utf8).write(to: output)
        let before = ImageGenerationService.modificationDate(output)
        #expect(!ImageGenerationService.madeAnew(output, before: before))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: output.path)
        #expect(ImageGenerationService.madeAnew(output, before: before))
        #expect(ImageGenerationService.madeAnew(output, before: nil))
    }

    @Test func aPictureKeptAfterFailingSaysSo() {
        #expect(PictureCheck.verdict("A beach.\nMATCH: YES") == true)
        #expect(PictureCheck.verdict("A studio.\nMATCH: NO") == false)
        #expect(PictureCheck.verdict("I cannot tell.") == nil)
        #expect(!PictureCheck.passed("I cannot tell."))
        #expect(PictureCheck.Outcome.passed.note.isEmpty)
        #expect(PictureCheck.Outcome.failedKept(tries: 3).note.contains("3 回作り直しても合格しなかった"))
        #expect(PictureCheck.Outcome.unchecked.note.contains("確かめられませんでした"))
    }
}
