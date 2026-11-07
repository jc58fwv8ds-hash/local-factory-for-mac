import AppKit
import Foundation
import SwiftUI
import Testing
@testable import HarnessApp
import HarnessCore

struct DailyNewsScheduleTests {
    @Test func timesAreTwoDigitHoursAndMinutes() {
        #expect(DailyNewsSchedule.time("05:30")! == (5, 30))
        #expect(DailyNewsSchedule.time("23:59")! == (23, 59))
        for bad in ["5:30", "24:00", "12:60", "１２:３０", "12-30", "", "12:3a"] { #expect(DailyNewsSchedule.time(bad) == nil, "\(bad)") }
    }

    @Test func theUploadJobExistsOnlyWhenTheUploadWaitsForItsOwnTime() {
        var s = DailyNewsSettings(); s.scriptsDirectory = "/tmp/news"
        #expect(DailyNewsSchedule.jobs(s).map(\.label) == [DailyNewsSchedule.produceLabel])
        s.youtube = true
        #expect(DailyNewsSchedule.jobs(s).map(\.label) == [DailyNewsSchedule.produceLabel])
        s.uploadAfterProduction = false; s.uploadTime = "07:15"
        let jobs = DailyNewsSchedule.jobs(s)
        #expect(jobs.map(\.label) == [DailyNewsSchedule.produceLabel, DailyNewsSchedule.uploadLabel])
        #expect(jobs[1].plist.contains("<key>Hour</key><integer>7</integer><key>Minute</key><integer>15</integer>"))
        #expect(jobs[1].plist.contains("<string>/tmp/news/run_daily.sh</string><string>upload</string>"))
        s.enabled = false
        #expect(DailyNewsSchedule.jobs(s).isEmpty)
    }
}

struct JobTimeEstimatesTests {
    @Test func theGuessIsTheMiddleOfTheLastRunsAndFallsBackToMeasuredFigures() {
        let estimates = JobTimeEstimates(defaults: UserDefaults(suiteName: "JobTimes-\(UUID().uuidString)")!)
        #expect(estimates.expected("chat:x") == nil)
        #expect(estimates.expected("image:z-image-turbo") == 60)
        for seconds in [10.0, 500, 30] { estimates.record("chat:x", seconds: seconds) }
        #expect(estimates.expected("chat:x") == 30)
        for _ in 0..<8 { estimates.record("chat:x", seconds: 5) }
        #expect(estimates.expected("chat:x") == 5)   // only the last seven count
    }

    @Test func theTextNeverCountsBelowZero() {
        #expect(JobTimeEstimates.text(expected: 300, elapsed: 100) == "残り およそ 4 分")
        #expect(JobTimeEstimates.text(expected: 30, elapsed: 21) == "残り およそ 9 秒")
        #expect(JobTimeEstimates.text(expected: 60, elapsed: 90) == "経過 2 分")
        #expect(JobTimeEstimates.text(expected: nil, elapsed: 5).hasPrefix("経過 5 秒"))
    }
}

struct DailyNewsProgressTests {
    private let running = DailyNewsProgress(state: "running", stage: "台本", detail: "", fraction: 0.5, startedAt: 1000, pid: 42)

    @Test func aJobWhoseProcessIsGoneCountsAsStopped() {
        #expect(running.isRunning(alive: { _ in true }) && !running.isStopped(alive: { _ in true }))
        #expect(!running.isRunning(alive: { _ in false }) && running.isStopped(alive: { _ in false }))
        var done = running; done.state = "done"
        #expect(!done.isRunning(alive: { _ in false }) && !done.isStopped(alive: { _ in false }))
    }

    @Test func theRemainingTimeComesFromTheSpeedSoFar() {
        #expect(running.remaining(now: 1000 + 3600) == "1 時間 0 分")
        #expect(running.remaining(now: 1000 + 600) == "10 分")
        var early = running; early.fraction = 0.01
        #expect(early.remaining(now: 2000) == nil)
    }
}

struct OutputFollowUpTests {
    @Test func aChangeKeepsTheLastPromptAndAnUnmarkedReplyCountsAsAChange() {
        #expect(OutputFollowUp.parse("EDIT: a red cat").prompt == "a red cat" && OutputFollowUp.parse("EDIT: a red cat").isEdit)
        #expect(OutputFollowUp.parse("new: a dog").prompt == "a dog" && !OutputFollowUp.parse("new: a dog").isEdit)
        #expect(OutputFollowUp.parse("a red cat").isEdit)
        #expect(OutputFollowUp.fallback(instruction: "もっと赤く", previousPrompt: "a cat") == "a cat. もっと赤く")
        let request = OutputFollowUp.request(instruction: "もっと赤く", previousPrompt: "a cat", kind: "image")
        #expect(request.contains("a cat") && request.contains("もっと赤く"))
    }
}

struct VideoOptionsTests {
    @Test func theLengthComesFromTheWordsAndATimeInTheStoryIsNotOne() {
        #expect(VideoLength.seconds(in: "猫が走る10秒の動画") == 10)
        #expect(VideoLength.seconds(in: "猫が走る１５秒の動画") == 15)
        #expect(VideoLength.seconds(in: "1分の動画") == 30)
        #expect(VideoLength.seconds(in: "3秒後に爆発する") == nil)
        #expect(VideoLength.seconds(in: "猫が走る") == nil)
    }

    @Test func aFlagWithoutItsValueIsLeftOut() {
        let template: ArraySlice<String> = ["--prompt", "{prompt}", "--seconds", "{seconds}", "--image", "{image}"]
        let output = URL(fileURLWithPath: "/tmp/o.mp4")
        #expect(ImageGenerationService.arguments(template, prompt: "p", output: output) == ["--prompt", "p"])
        #expect(ImageGenerationService.arguments(template, prompt: "p", output: output, seconds: 5, image: URL(fileURLWithPath: "/tmp/a.png"))
            == ["--prompt", "p", "--seconds", "5", "--image", "/tmp/a.png"])
    }

    @Test func aLengthNeverMadeIsGuessedInProportion() {
        let estimates = JobTimeEstimates(defaults: UserDefaults(suiteName: "JobTimes-\(UUID().uuidString)")!)
        #expect(estimates.expected("image:wan22-5b@6s") == 1200)
    }

    @Test func finishedVideosAreListedNewestFirstWithoutTrialCuts() {
        let names = ["AI研究ニュース-2026-11-02.mp4", "AI研究ニュース-2026-11-04.mp4", "AI研究ニュース-2026-11-04.md",
                     "長い版の試し-2026-11-02.mp4", "長い版の試し-2026-11-02-最初の4分.mp4"]
        #expect(DailyNewsStore.videoDates(in: names) == ["2026-11-04", "2026-11-02"])
    }

    @Test func aRequestThatPointsBackGetsTheEarlierConversation() {
        let cat = ConversationMessage(role: .user, content: "ニューヨークの雑踏のなかを歩く黒猫", origin: .user)
        let note = ConversationMessage(role: .assistant, content: "画像ができました(Z-Image)。保存先: /tmp/a.png", origin: .user)
        let now = ConversationMessage(role: .user, content: "さっきの内容で画像にして(写実的に)", origin: .user)
        let later = ConversationMessage(role: .user, content: "あとの指示", origin: .user)
        let text = OutputFollowUp.earlierConversation([cat, note, now, later], before: now.id)
        #expect(text.contains("User: ニューヨークの雑踏のなかを歩く黒猫"))
        #expect(!text.contains("画像ができました"))
        #expect(!text.contains("さっきの内容で画像にして"))
        #expect(!text.contains("あとの指示"))
        #expect(OutputFollowUp.earlierConversation([now], before: now.id).isEmpty)
    }

    @Test func cancellingARunStopsTheProgramAtOnce() async throws {
        let started = Date()
        let run = Task { try await ImageGenerationService.run(URL(fileURLWithPath: "/bin/sleep"), ["30"]) }
        try await Task.sleep(for: .milliseconds(300))
        run.cancel()
        _ = try await run.value
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aDeletedChatTakesOnlyTheFilesItNamesInTheImageFolder() {
        let folder = URL(fileURLWithPath: "/tmp/App Support/Images")
        let files = WorkspaceStore.generatedFiles(in: [
            "画像ができました(Z)。保存先: /tmp/App Support/Images/ab-z.png",
            "/tmp/App Support/Images/cd-v.mp4。次へ",
            "/tmp/App Support/Images/../secret.png と /tmp/other/x.png と /tmp/App Support/Images/note.txt"
        ], folder: folder)
        #expect(files.map(\.lastPathComponent) == ["ab-z.png", "cd-v.mp4"])
    }

    @Test func aDeletedChatLeavesTheModelLogButOthersStay() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("calls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("2026-11-05.jsonl")
        for (text, answer) in [("消すチャットの長い文章です", "答え"), ("別のチャット", "別の答え"), ("はい、消すチャットの長い文章ですを英語に", "x"), ("はいはい", "短い")] {
            let request = InferenceRequest(runtime: .ollama, modelIdentifier: "m", messages: [InferenceMessage(role: .user, content: text)], maximumOutputTokens: 1)
            ModelCallLog.record(request, response: answer, error: nil, seconds: 1, to: file)
        }
        ModelCallLog.remove(mentioning: ["消すチャットの長い文章です", "はい"], in: folder)
        let left = try String(contentsOf: file, encoding: .utf8)
        #expect(!left.contains("消すチャット"))
        #expect(left.contains("別のチャット"))
        #expect(left.contains("はいはい"))
    }

    @MainActor @Test func aFinishedVideoCanBeShownWithoutStoppingTheApp() {
        let host = NSHostingView(rootView: VideoPreview(url: URL(fileURLWithPath: "/tmp/none.mp4")).frame(width: 320, height: 180))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        host.layoutSubtreeIfNeeded()
        #expect(host.subviews.isEmpty == false || host.fittingSize.width > 0)
    }

    @Test func onlyTheAppCanSayAFileWasMade() {
        let real = "動画ができました(Wan)。保存先: /tmp/App Support/Images/a.mp4"
        #expect(GeneratedMedia.file(inNote: real)?.path == "/tmp/App Support/Images/a.mp4")
        #expect(GeneratedMedia.claimsUnmadeFile(real, exists: { _ in false }))
        #expect(!GeneratedMedia.claimsUnmadeFile(real, exists: { _ in true }))
        #expect(GeneratedMedia.claimsUnmadeFile("はい。動画を生成しました。"))
        #expect(!GeneratedMedia.claimsUnmadeFile("黒猫は静かに歩いていた。"))
    }

    @Test(arguments: [("上空からパンするようなカメラワークで再度動画を生成して", GeneratedMedia.Kind.video), ("この画像を動かして", .video),
                      ("さっきの内容で画像にして(写実的に)", .image), ("猫の写真を作って", .image)])
    func requestsInWordsGoToTheModelThatCanMakeThem(text: String, kind: GeneratedMedia.Kind) {
        #expect(GeneratedMedia.requestedKind(text) == kind)
    }

    @Test(arguments: ["ニューヨークの雑踏のなかを歩く黒猫", "動画の作り方を教えて", "この画像は何ですか?", "画像を作った人は誰", "プログラムを動かして"])
    func otherMessagesStayInTheChat(text: String) {
        #expect(GeneratedMedia.requestedKind(text) == nil)
    }

    @Test func aVideoCanStartFromTheLastPictureThatStillExists() {
        let notes = ["画像ができました(Z)。保存先: /tmp/a.png", "動画ができました(W)。保存先: /tmp/b.mp4", "画像ができました(Z)。保存先: /tmp/gone.png"]
        #expect(GeneratedMedia.lastFile(.image, in: notes, exists: { $0.lastPathComponent != "gone.png" })?.lastPathComponent == "a.png")
        #expect(GeneratedMedia.lastFile(.video, in: notes, exists: { _ in true })?.lastPathComponent == "b.mp4")
    }

    @Test func aRecipeSurvivesARestart() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("recipe-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("json"))
        }
        WorkspaceStore.saveRecipe(prompt: "no file yet", seed: 1, for: file)
        #expect(WorkspaceStore.savedRecipe(for: file) == nil)
        try Data().write(to: file)
        WorkspaceStore.saveRecipe(prompt: "a black cat", seed: 7, for: file)
        let saved = try #require(WorkspaceStore.savedRecipe(for: file))
        #expect(saved.prompt == "a black cat" && saved.seed == 7)
    }

    @Test func theLineShowsWhereTheTimeWent() {
        let start = Date(timeIntervalSince1970: 0)
        var stages = InferenceStages()
        stages.enter(.waiting, at: start)
        stages.enter(.loading, at: start)
        stages.enter(.reading, at: start.addingTimeInterval(3))
        #expect(stages.summary(at: start.addingTimeInterval(4)) == "読み込み 3.0秒 · 入力 1.0秒")
        stages.piece(at: start.addingTimeInterval(6.5))
        for n in 1...20 { stages.piece(at: start.addingTimeInterval(6.5 + Double(n) / 10)) }
        stages.finish(at: start.addingTimeInterval(8.5))
        #expect(stages.summary(at: start.addingTimeInterval(9)) == "読み込み 3.0秒 · 入力 3.5秒 · 出力 2.0秒(10.5/秒)")
    }

    @Test func aWritersRefusalNeverBecomesThePicture() {
        #expect(ModelRefusal.looksLikeRefusal("I cannot fulfill the request to generate an image involving sexual acts or explicit content. I am designed to be a helpful and harmless AI assistant"))
        #expect(!ModelRefusal.looksLikeRefusal("A seductive married woman in an abandoned building, soft light"))
    }

    @Test func aRequestAboutThisPersonStartsFromTheLastPicture() {
        #expect(GeneratedMedia.pointsAtLastImage("この人物をマスターベーションさせて"))
        #expect(!GeneratedMedia.pointsAtLastImage("猫の写真を作って"))
    }

    @Test func aNewVideoAsksForTheActionTheHandsAndTheCamera() {
        let text = OutputFollowUp.videoRequest(instruction: "猫が走る", hasPicture: true)
        #expect(text.contains("猫が走る") && text.contains("2. Second sentence") && text.contains("only the person's looks") && text.contains("5. End with"))
        #expect(OutputFollowUp.videoRequest(instruction: "猫が走る", hasPicture: false).contains("4. End with"))
    }
}
