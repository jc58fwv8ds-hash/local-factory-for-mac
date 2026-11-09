import Foundation
import Testing
import HarnessCore

struct VideoScriptTests {
    @Test func namedLinesKeepTheirSpeakersAndUnnamedFollowTheOneBefore() {
        let lines = VideoScript.parse("""
        美咲: ねえ、こっちを見て。
        健太「どうしたの?」

        もう少し近くで
        美咲：ふふっ…
        あっ…んっ…
        """)
        #expect(lines == [
            .init(speaker: "美咲", text: "ねえ、こっちを見て。"),
            .init(speaker: "健太", text: "どうしたの?"),
            .init(speaker: "健太", text: "もう少し近くで"),
            .init(speaker: "美咲", text: "ふふっ…"),
            .init(speaker: "美咲", text: "あっ…んっ…"),
        ])
        #expect(VideoScript.speakers(lines) == ["美咲", "健太"])
    }

    @Test func eachSpeakerHasAVoiceAndSeedOfTheirOwn() {
        let speakers = ["女", "男", "友人の女"]
        #expect(VideoScript.caption(for: "男", among: speakers).contains("男性"))
        #expect(VideoScript.caption(for: "女", among: speakers).contains("女性"))
        #expect(VideoScript.caption(for: "女", among: speakers) != VideoScript.caption(for: "友人の女", among: speakers))
        #expect(Set(speakers.map { VideoScript.seed(7, speaker: $0, among: speakers) }).count == 3)
    }

    @Test func aSentenceIsNotTakenForAName() {
        #expect(VideoScript.parse("それで、彼が言ったの: 帰ろうって") == [.init(speaker: "", text: "それで、彼が言ったの: 帰ろうって")])
    }
}

struct FaceLockTests {
    @Test func outputSitsBesideTheOthersAndProgressReadsAsFrames() throws {
        let folder = URL(fileURLWithPath: "/tmp/out")
        let date = Date(timeIntervalSince1970: 0)
        #expect(FaceLock.output(for: URL(fileURLWithPath: "/a/clip.mov"), in: folder, at: date).lastPathComponent.hasPrefix("clip-顔入替-"))
        let command = FaceLock.command(face: URL(fileURLWithPath: "/f.png"), video: URL(fileURLWithPath: "/v.mp4"),
                                       output: URL(fileURLWithPath: "/o.mp4"), progress: URL(fileURLWithPath: "/p"),
                                       home: URL(fileURLWithPath: "/h"))
        #expect(command.program.path == "/h/Tools/FaceSwap/.venv/bin/python")
        #expect(command.arguments.contains("/h/Tools/ImageEngines/face_lock.py") && command.arguments.contains("--progress"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("face-lock-progress-test.json")
        try Data(#"{"done": 36, "of": 300}"#.utf8).write(to: file)
        #expect(FaceLock.progressLine(file) == "36 / 300 コマ")
        try? FileManager.default.removeItem(at: file)
    }
}
