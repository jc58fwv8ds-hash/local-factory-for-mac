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
        #expect(JobTimeEstimates.text(expected: 60, elapsed: 90) == "いつもより長くかかっています(経過 2 分)")
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
        // A follow-up must keep the asked action (2026-11-08: 「自慰に耽らせた画像」 after a picture became a change of clothes).
        #expect(request.contains("never soften, leave out or replace it"))
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
        // No camera move the request did not ask for (2026-11-08: an unasked close glide cut the face out of the frame).
        #expect(text.contains("The camera stays steady, with her whole body and face in frame."))
    }

    @Test func aWordInTheRequestAlwaysAddsItsMotion() {
        var catalog = PurposeModelCatalog()
        catalog.motionHints = ["走る": "She runs fast.", "疾走": "She runs fast.", "踊る": "She dances."]
        #expect(catalog.motionHints(for: "猫と走る、疾走する") == ["She runs fast."])
        #expect(catalog.motionHints(for: "座る").isEmpty)
    }

    @Test func aJapaneseWordInTheRequestGetsItsMeaning() {
        var catalog = PurposeModelCatalog()
        catalog.termHints = ["アトリエ": "an artist's studio", "浴衣": "a cotton yukata"]
        #expect(catalog.termHints(for: "浴衣でアトリエに") == ["「アトリエ」 = an artist's studio", "「浴衣」 = a cotton yukata"])
        #expect(catalog.termHints(for: "公園").isEmpty)
        // The bundled catalog carries the words that went wrong in the app test (2026-11-08).
        let bundled = PurposeModelCatalog.load(from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config/purpose-models.json"))
        // The public export ships its own catalog without these; the check is for the full one.
        if bundled.termHints != nil { #expect(bundled.termHints?["アトリエ"] != nil && bundled.termHints?["浴衣"] != nil) }
    }
}

struct GeneratedStepsTests {
    @Test func theStepsBesideAPictureAreListedInOrderAndAMissingFolderIsNone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("steps-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = folder.appendingPathComponent("A-keep-person.png")
        let steps = GeneratedMedia.stepsFolder(of: picture)
        try FileManager.default.createDirectory(at: steps, withIntermediateDirectories: true)
        for name in ["3-はだけ.png", "1-着替え.png", "2-はだけ.mp4", ".DS_Store"] {
            try Data().write(to: steps.appendingPathComponent(name))
        }
        #expect(GeneratedMedia.steps(of: picture).map(\.lastPathComponent) == ["1-着替え.png", "2-はだけ.mp4", "3-はだけ.png"])
        #expect(GeneratedMedia.steps(of: folder.appendingPathComponent("none.png")).isEmpty)
    }
}

struct VoiceLineTests {
    @Test func aVoiceIsAddedOnlyWhenTheRequestAsksForOne() {
        #expect(VoiceLine.wanted("この画像を動画にして、喘ぎ声も入れて"))
        #expect(VoiceLine.wanted("動画にして「おはよう」と言わせて"))
        #expect(!VoiceLine.wanted("猫が走る動画を作って"))
    }

    @Test func theWordsAndTheVoiceComeFromTwoLines() {
        let line = VoiceLine.parse("TEXT: 🥵あっ…はぁ…\nCAPTION: 吐息まじりの三十代の女性の声")
        #expect(line?.text == "🥵あっ…はぁ…" && line?.caption == "吐息まじりの三十代の女性の声")
        #expect(VoiceLine.parse("TEXT: こんにちは") == nil)
        // The request read out as the words is replaced (2026-11-08).
        let request = "この画像を動画にして、自慰を続けさせて喘ぎ声も入れて"
        #expect(VoiceLine.words("自慰を続けさせて喘ぎ声も入れて", instruction: request) == VoiceLine.moaning)
        #expect(VoiceLine.words("🥵あっ…んっ…はぁ…", instruction: request) == "🥵あっ…んっ…はぁ…")
        #expect(VoiceLine.words("おはようと言わせて", instruction: "動画にして、おはようと言わせて") == nil)
        #expect(VoiceLine.words("ねえ、こっちを見て。ずっと待ってたの。", instruction: "動画にして「ねえ、こっちを見て。ずっと待ってたの。」と話しかけさせて")
                == "ねえ、こっちを見て。ずっと待ってたの。")
        #expect(VoiceLine.writerRequest(instruction: "「好き」と言って", videoPrompt: "a woman").contains("「」 exactly"))
    }

    @Test func theBundledCatalogHasTheVoiceCommand() {
        let bundled = PurposeModelCatalog.load(from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config/purpose-models.json"))
        if bundled.voiceCommand != nil { #expect(bundled.voiceCommand?.contains("{caption}") == true) }
    }
}

struct FollowUpRoutingTests {
    @Test func aChangeToTheLastPictureIsAPictureEvenWithoutTheWord() {
        #expect(GeneratedMedia.requestedKind("この人物を全裸にして", lastMade: .image) == .image)
        #expect(GeneratedMedia.requestedKind("さっきの条件で生成", lastMade: .image) == .image)
        #expect(GeneratedMedia.requestedKind("さっきの条件で生成", lastMade: .video) == .video)
        #expect(GeneratedMedia.requestedKind("この人物を全裸にして") == nil)
        #expect(GeneratedMedia.requestedKind("この人物について教えて", lastMade: .image) == nil)
        #expect(GeneratedMedia.requestedKind("今日の予定をまとめて", lastMade: .image) == nil)
        #expect(GeneratedMedia.requestedKind("顔も写るように引いて、腕を組ませて", lastMade: .image, justMade: true) == .image)
        #expect(GeneratedMedia.requestedKind("腕を１本に戻して。", lastMade: .video, justMade: true) == .video)
        #expect(GeneratedMedia.requestedKind("腕を組ませて", lastMade: .image) == nil)
        #expect(GeneratedMedia.requestedKind("今日の予定をまとめて", lastMade: .image, justMade: true) == nil)
        #expect(GeneratedMedia.requestedKind("どう思う？", lastMade: .image, justMade: true) == nil)
        #expect(GeneratedMedia.requestedKind("ありがとう", lastMade: .image, justMade: true) == nil)
    }

    @Test func theLastMadeKindComesFromTheNotes() {
        let notes = ["画像ができました(x)。保存先: /tmp/a.png", "こんにちは", "動画ができました(y)。保存先: /tmp/b.mp4"]
        #expect(GeneratedMedia.lastMadeKind(in: notes) == .video)
        #expect(GeneratedMedia.lastMadeKind(in: ["こんにちは"]) == nil)
    }
}

struct TimeLimitTests {
    @Test func thePictureModelThatKeepsAPersonMayRunAnHour() {
        let bundled = PurposeModelCatalog.load(from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config/purpose-models.json"))
        if bundled.option(id: "keep-person", for: .image) != nil { #expect(bundled.option(id: "keep-person", for: .image)?.timeLimit == 3600) }
        #expect(bundled.option(id: "z-image-turbo", for: .image)?.timeLimit == nil)
    }
}

struct GenerationProgressTests {
    @Test func theScriptsStepsBecomeABarAndAMissingFileIsNone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("a.png")
        try Data(#"{"step": 3, "of": 6, "label": "顔を元の人物に"}"#.utf8).write(to: GenerationProgress.file(for: output))
        let read = try #require(GenerationProgress.read(for: output))
        #expect(read.label == "顔を元の人物に" && abs(read.fraction - 2.5 / 6) < 0.001)
        #expect(GenerationProgress.read(for: folder.appendingPathComponent("b.png")) == nil)
    }
}

struct StillVideoTests {
    @Test func theVideoModelRemakesAStillClipAndTheActionComesFirst() {
        let bundled = PurposeModelCatalog.load(from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config/purpose-models.json"))
        // Every video model that starts from a picture with the motion check has it (the bundled catalog's own names).
        if bundled.motionHints != nil { #expect(bundled.video?.contains { $0.command?.contains("--min-motion") == true } == true) }
        if bundled.motionHints != nil { #expect(bundled.motionHints(for: "自慰").first?.hasPrefix("She slides one hand down between her thighs") == true) }
    }
}

struct SpeechFirstTests {
    @Test func theVoiceGoesToTheVideoCommandOnlyWhenThereIsOne() {
        let template: ArraySlice<String> = ["--image", "{image}", "--audio", "{audio}", "--output", "{output}"]
        let output = URL(fileURLWithPath: "/tmp/v.mp4")
        #expect(ImageGenerationService.arguments(template, prompt: "p", output: output, audio: URL(fileURLWithPath: "/tmp/a.wav"))
                == ["--audio", "/tmp/a.wav", "--output", "/tmp/v.mp4"])
        #expect(ImageGenerationService.arguments(template, prompt: "p", output: output) == ["--output", "/tmp/v.mp4"])
    }
}

struct PictureCheckTests {
    @Test func onlyAPlainYesKeepsTheQuickPicture() {
        #expect(PictureCheck.passed("She sits naked with a hand between her legs.\nMATCH: YES"))
        #expect(PictureCheck.passed("naked on a bed\nmatch: yes"))
        #expect(!PictureCheck.passed("She stands in a sweater.\nMATCH: NO"))
        #expect(!PictureCheck.passed("YES"))
        #expect(!PictureCheck.passed(""))
        #expect(PictureCheck.request(prompt: "a cat on a sofa").contains("a cat on a sofa"))
    }
}

struct LongVideoPlanTests {
    @Test func aLengthBeyondOneClipBecomesScenes() {
        #expect(LongVideoPlan.requestedSeconds(in: "1分の動画にして") == 60)
        #expect(LongVideoPlan.requestedSeconds(in: "10分の動画") == 600)
        #expect(LongVideoPlan.requestedSeconds(in: "45分の動画") == 1800)
        #expect(LongVideoPlan.sceneCount(seconds: 60) == 20)
        #expect(LongVideoPlan.sceneCount(seconds: 10) == 3)
        #expect(LongVideoPlan.sceneCount(seconds: 3) == nil)
        #expect(LongVideoPlan.sceneCount(seconds: 30) == 10)
        #expect(LongVideoPlan.intensity(scene: 0, of: 10).contains("slow") && LongVideoPlan.intensity(scene: 9, of: 10).contains("intense"))
        // Stronger, not faster (2026-11-09: fast motion broke the hand up).
        #expect(!(0..<10).contains { LongVideoPlan.intensity(scene: $0, of: 10).contains("fast") || LongVideoPlan.intensity(scene: $0, of: 10).contains("frantic") })
        // Words and hand actions in separate scenes, so the talking is lip-synced and the action follows the skeleton.
        let request = LongVideoPlan.writerRequest(instruction: "自慰しながら話して", videoPrompt: "", scenes: 4, withVoice: true)
        #expect(request.contains("Keep words and hand actions in separate scenes"))
        // Moans only go over a guided action; words make the clip speech-first.
        #expect(VoiceLine.moansOnly("🥵あっ…んっ…🌬はぁ…") && VoiceLine.moansOnly("はぁ…はぁ…"))
        #expect(!VoiceLine.moansOnly("もっと見て") && !VoiceLine.moansOnly("あっ、だめ…") && !VoiceLine.moansOnly("気持ちいい…"))
        #expect(VoiceLine.fileSuffix(VoiceLine.moaning) == "-voice-moans.wav" && VoiceLine.fileSuffix("ねえ、見て") == "-voice.wav")
        // A voice file made elsewhere is the lines (2026-11-09): sound files are taken, others are not; a long video gets
        // it as --voice only when one is attached.
        #expect(WorkspaceStore.isVoiceFile(URL(fileURLWithPath: "/tmp/a.MP3")) && WorkspaceStore.isVoiceFile(URL(fileURLWithPath: "/tmp/b.wav")))
        #expect(!WorkspaceStore.isVoiceFile(URL(fileURLWithPath: "/tmp/c.png")))
        let long = ["--plan", "{plan}", "--voice", "{audio}"][...]
        let out = URL(fileURLWithPath: "/tmp/o.mp4"), plan = URL(fileURLWithPath: "/tmp/p.json")
        #expect(ImageGenerationService.arguments(long, prompt: "p", output: out, plan: plan) == ["--plan", "/tmp/p.json"])
        #expect(ImageGenerationService.arguments(long, prompt: "p", output: out, audio: URL(fileURLWithPath: "/tmp/v.m4a"), plan: plan)
                == ["--plan", "/tmp/p.json", "--voice", "/tmp/v.m4a"])
    }

    @Test func theScenesComeFromTheWritersJSONAndTheRestIsFilled() {
        let reply = #"Here: {"scenes": [{"prompt": "a", "text": "やあ", "caption": "声"}, {"prompt": "b", "restart": true}]}"#
        let scenes = LongVideoPlan.parse(reply, scenes: 3, fallback: "whole")
        #expect(scenes.map(\.prompt) == ["a", "b", "whole"])
        #expect(scenes[0].text == "やあ" && scenes[1].text == "")
        #expect(!scenes[0].restart && scenes[1].restart)
        #expect(LongVideoPlan.parse("no json", scenes: 2, fallback: "whole").map(\.prompt) == ["whole", "whole"])
    }
}

struct LongVideoCommandTests {
    @Test func thePlanGoesOnlyToACommandThatTakesIt() {
        let template: ArraySlice<String> = ["--plan", "{plan}", "--image", "{image}", "--output", "{output}"]
        let output = URL(fileURLWithPath: "/tmp/v.mp4")
        #expect(ImageGenerationService.arguments(template, prompt: "p", output: output, plan: URL(fileURLWithPath: "/tmp/p.json"))
                == ["--plan", "/tmp/p.json", "--output", "/tmp/v.mp4"])
        let bundled = PurposeModelCatalog.load(from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config/purpose-models.json"))
        if bundled.motionHints != nil { #expect(bundled.video?.contains { $0.longCommand?.contains("{plan}") == true } == true) }
    }
}

struct LongVideoChapterTests {
    @Test func aLongVideoIsWrittenAsChaptersFirst() {
        #expect(LongVideoPlan.parseChapters(#"{"chapters": ["on the sofa", "by the window"]}"#, chapters: 3, fallback: "x")
                == ["on the sofa", "by the window", "by the window"])
        #expect(LongVideoPlan.parseChapters("none", chapters: 2, fallback: "x") == ["x", "x"])
        #expect(LongVideoPlan.chapterRequest(instruction: "i", videoPrompt: "p", chapters: 4).contains("4 parts"))
    }
}

struct TrainingMaterialsTests {
    @Test func setsHoldCopiesOfPicturesAndVideosFromFilesAndFolders() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("training-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("inner"), withIntermediateDirectories: true)
        for name in ["a.png", "inner/b.mp4", "notes.txt"] { try Data([1]).write(to: source.appendingPathComponent(name)) }
        let materials = TrainingMaterials(root: base.appendingPathComponent("Training"))
        let name = try materials.addSet(named: "浴衣")
        #expect(try materials.addSet(named: "浴衣") == "浴衣 2")
        #expect(try materials.add([source], to: name) == 2)
        #expect(try materials.add([source.appendingPathComponent("a.png")], to: name) == 1)
        let set = try #require(materials.sets().first { $0.name == "浴衣" })
        #expect(set.pictures == 2 && set.videos == 1)
        #expect(set.files.map(\.lastPathComponent).contains("a 2.png"))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("a.png").path))
    }
}
