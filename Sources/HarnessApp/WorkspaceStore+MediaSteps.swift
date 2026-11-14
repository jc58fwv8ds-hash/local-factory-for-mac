import AVFoundation
import Foundation
import HarnessCore

/// Steps around making a picture or video (2026-11-08): the voice the request asks for, and the quick first try of a
/// picture model checked by the prompt writer looking at it.
extension WorkspaceStore {
    /// The words she says and the voice they are read in, from the prompt writer (2026-11-08); moaning when the request asks
    /// for it and the writer gave nothing usable; nil when there is nothing to say.
    func voiceLine(instruction: String, videoPrompt: String, writer: ModelSelection) async -> (text: String, caption: String)? {
        let request = InferenceRequest(runtime: writer.runtime, modelIdentifier: writer.identifier, messages: [
            InferenceMessage(role: .user, content: VoiceLine.writerRequest(instruction: instruction, videoPrompt: videoPrompt))
        ], maximumOutputTokens: 200, temperature: 0)
        var reply = ""
        do {
            for try await piece in await inferenceProvider.events(for: request) { reply += piece }
        } catch { reply = "" }
        let parsed = ModelRefusal.looksLikeRefusal(reply) ? nil : VoiceLine.parse(reply)
        let caption = parsed?.caption ?? "吐息まじりの、近い距離感の大人の女性の声"
        guard let text = VoiceLine.words(parsed?.text ?? "", instruction: instruction).flatMap({ $0.isEmpty ? nil : $0 })
                ?? (["喘", "あえぎ"].contains(where: instruction.contains) ? VoiceLine.moaning : nil) else { return nil }
        return (text, caption)
    }

    /// Runs a voice command (catalog `speechCommand` or `voiceCommand`) with its values; true when it finished.
    func runVoice(_ command: [String], _ values: [String: String]) async -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let arguments = command.map { values[$0] ?? $0.replacingOccurrences(of: "{home}", with: home) }
        guard let program = arguments.first else { return false }
        return (try? await ImageGenerationService.run(URL(fileURLWithPath: program), Array(arguments.dropFirst()), limit: 600)) != nil
    }

    /// Makes the picture the quick way and keeps it when the prompt writer, looking at it, says it shows what was asked;
    /// otherwise removes it so the full way runs (2026-11-08).
    func quickPictureHolds(_ command: [String], option: PurposeModelOption, prompt: String, output: URL,
                                   options: ImageGenerationOptions, writer: ModelSelection?) async -> Bool {
        var quick = option
        quick.command = command
        quick.firstTry = nil
        guard (try? await imageGenerator.generate(option: quick, prompt: prompt, output: output, options: options)) != nil,
              !Task.isCancelled, let writer, let data = try? Data(contentsOf: output) else {
            try? FileManager.default.removeItem(at: output)
            return false
        }
        if await pictureShowsRequest(data, prompt: prompt, writer: writer) == true { return true }
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.removeItem(at: GeneratedMedia.stepsFolder(of: output))
        return false
    }

    /// Whether the writer, looking at the picture, says it shows what was asked with an unbroken body (PictureCheck); nil
    /// when the check could not run.
    func pictureShowsRequest(_ data: Data, prompt: String, writer: ModelSelection) async -> Bool? {
        let request = InferenceRequest(runtime: writer.runtime, modelIdentifier: writer.identifier, messages: [
            InferenceMessage(role: .user, content: PictureCheck.request(prompt: prompt))
        ], maximumOutputTokens: 120, images: await ComputerUseScreenshot.inferenceImages(data), temperature: 0)
        var reply = ""
        do {
            for try await piece in await inferenceProvider.events(for: request) { reply += piece }
        } catch { return nil }
        return PictureCheck.passed(reply)
    }

    /// The full way, checked too, and made again with another seed when the check fails (2026-11-14, the user: 「2の確認は
    /// 最終画像にも入れてください。不合格なら作り直しで、数分増えるのは構いません」; a picture with four arms had passed
    /// unchecked). Up to two more tries; the last one is kept when none passes. Returns the seed of the picture kept.
    func checkedPicture(option: PurposeModelOption, prompt: String, output: URL, options: ImageGenerationOptions, isVideo: Bool,
                        writer: ModelSelection?, status: (String) -> Void) async throws -> Int {
        var options = options
        for attempt in 0..<(isVideo || writer == nil ? 1 : PictureCheck.tries) {
            if attempt > 0 {
                status("確かめた結果、頼みと合わない所があったので作り直しています(\(attempt + 1) 回目)")
                options.seed += 7_919 * attempt
                try? FileManager.default.removeItem(at: GeneratedMedia.stepsFolder(of: output))
            }
            try await imageGenerator.generate(option: option, prompt: prompt, output: output, options: options)
            guard !Task.isCancelled, !isVideo, let writer, let data = try? Data(contentsOf: output) else { break }
            if await pictureShowsRequest(data, prompt: prompt, writer: writer) != false { break }  // unchecked is kept
        }
        return options.seed
    }

    /// A video longer than one clip: the prompt writer splits it into scenes, each made from where the one before ended
    /// with its own voice, and joined into one file (2026-11-08).
    func makeLongVideo(_ command: [String], scenes: Int, option: PurposeModelOption, prompt: String, instruction: String,
                       output: URL, image: URL?, seed: Int, writer: ModelSelection?, voice: URL? = nil) async throws {
        // An attached voice file is the lines (spread over the scenes by long_video.py); none is written then.
        let withVoice = voice == nil && VoiceLine.wanted(instruction)
        // Up to a minute as one list of scenes; longer, first as chapters, then each chapter as its scenes (2026-11-08).
        // The writer sees the starting picture, so it can tell whether the first scene is somewhere else (2026-11-14: told
        // nothing, it was held to the picture, and 「東京駅の正面入り口を歩かせて」 stayed on the beach of the picture).
        let picture = await ComputerUseScreenshot.inferenceImages(image.flatMap { try? Data(contentsOf: $0) })
        func ask(_ content: String, tokens: Int, images: [InferenceImage] = []) async -> String {
            guard let writer else { return "" }
            let request = InferenceRequest(runtime: writer.runtime, modelIdentifier: writer.identifier,
                                           messages: [InferenceMessage(role: .user, content: content + (images.isEmpty ? "" : "\nThe attached picture is where the video starts."))],
                                           maximumOutputTokens: tokens, images: images, temperature: 0)
            var reply = ""
            do {
                for try await piece in await inferenceProvider.events(for: request) { reply += piece }
            } catch { reply = "" }
            return reply
        }
        var written: [LongVideoPlan.Scene] = []
        if scenes <= LongVideoPlan.scenesPerChapter * 2 {
            var reply = await ask(LongVideoPlan.writerRequest(instruction: instruction, videoPrompt: prompt, scenes: scenes, withVoice: withVoice),
                                  tokens: 260 * scenes, images: picture)
            if reply.isEmpty, !picture.isEmpty {
                reply = await ask(LongVideoPlan.writerRequest(instruction: instruction, videoPrompt: prompt, scenes: scenes, withVoice: withVoice), tokens: 260 * scenes)
            }
            written = LongVideoPlan.parse(reply, scenes: scenes, fallback: prompt)
        } else {
            let count = (scenes + LongVideoPlan.scenesPerChapter - 1) / LongVideoPlan.scenesPerChapter
            let chapters = LongVideoPlan.parseChapters(await ask(LongVideoPlan.chapterRequest(instruction: instruction, videoPrompt: prompt, chapters: count),
                                                                 tokens: 120 * count), chapters: count, fallback: prompt)
            for (index, chapter) in chapters.enumerated() {
                guard !Task.isCancelled else { return }
                let size = min(LongVideoPlan.scenesPerChapter, scenes - index * LongVideoPlan.scenesPerChapter)
                let reply = await ask(LongVideoPlan.writerRequest(instruction: instruction + "\nThis part: " + chapter, videoPrompt: chapter,
                                                                  scenes: size, withVoice: withVoice), tokens: 260 * size)
                written += LongVideoPlan.parse(reply, scenes: size, fallback: chapter)
            }
        }
        let hints = purposeSettings.catalog.motionHints(for: instruction)
        let plan = written.enumerated().map { index, scene -> LongVideoPlan.Scene in
            var scene = scene
            if let first = hints.first, !scene.prompt.contains(first) {
                // Rising within each chapter of a long video, over the whole of a short one.
                let per = scenes > LongVideoPlan.scenesPerChapter * 2 ? LongVideoPlan.scenesPerChapter : scenes
                scene.prompt = hints.joined(separator: " ") + " " + LongVideoPlan.intensity(scene: index % per, of: per) + " " + scene.prompt
            }
            scene.text = withVoice ? (VoiceLine.words(scene.text, instruction: instruction) ?? "") : ""
            // With a picture the writer did not see, the video starts from it (2026-11-13: marked new without seeing it, the
            // person of the picture was gone). Seen, a first scene somewhere else starts from a new picture of the same person.
            if index == 0, image != nil, picture.isEmpty { scene.restart = false }
            return scene
        }
        let file = Self.imageFolder.appendingPathComponent("\(output.deletingPathExtension().lastPathComponent)-plan.json")
        try JSONEncoder().encode(["scenes": plan]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var long = option
        long.command = command
        long.firstTry = nil
        long.timeLimit = Double(scenes) * 900
        try await imageGenerator.generate(option: long, prompt: prompt, output: output,
                                          options: ImageGenerationOptions(seed: seed, seconds: LongVideoPlan.sceneSeconds, image: image, audio: voice, plan: file))
    }

    /// How long a sound file plays, in seconds.
    /// The user's own lines, one voice per speaker, joined into the voice the mouth moves to (2026-11-10).
    func voiceTheScript(_ change: ImageChange, noun: String) async {
        guard change.isVideo, change.voiceFile == nil, change.speech == .script, let command = purposeSettings.catalog.speechCommand else { return }
        change.status = .running("セリフの声を作っています")
        change.voiceFile = await scriptVoice(change.script, command: command, seed: change.seed, name: String(change.id.uuidString.prefix(8)))
        change.status = .running("\(noun)を作っています")
    }

    /// The face every picture and video of the conversation is put back to: the first person picture attached in it, kept
    /// as face-<conversation>.png, replaced only when another picture is attached (2026-11-10, the user: 「画像生成を続けると
    /// 顔面の固定がブレる」: each follow-up took the last result as the person, so the face drifted a little more each time).
    static func originalFace(_ change: ImageChange) -> URL? {
        guard let face = change.face else { return nil }
        let file = imageFolder.appendingPathComponent("face-\(face.project.uuidString).png")
        if let data = face.attached { try? data.write(to: file) }
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// A video's extra pictures written beside the reference, as the keyframes its command is given (2026-11-10).
    static func keyframeFiles(_ change: ImageChange) -> [URL] {
        guard change.isVideo else { return [] }
        return change.keyframeImages.enumerated().compactMap { index, data in
            let file = imageFolder.appendingPathComponent("\(change.id.uuidString.prefix(8))-key\(index + 1).png")
            return (try? data.write(to: file)) != nil ? file : nil
        }
    }

    /// The user's lines read by one voice per speaker and joined in order with a short pause between them (2026-11-10, the
    /// user: 「セリフは複数人分を読み込んでも分けて音声でつくと良いかな」); nil when no line could be read.
    func scriptVoice(_ script: String, command: [String], seed: Int, name: String) async -> URL? {
        let lines = VideoScript.parse(script)
        let speakers = VideoScript.speakers(lines)
        var pieces: [URL] = []
        defer { for piece in pieces { try? FileManager.default.removeItem(at: piece) } }
        for (index, line) in lines.enumerated() {
            guard !Task.isCancelled else { return nil }
            let piece = Self.imageFolder.appendingPathComponent("\(name)-line\(index + 1).wav")
            let values = ["{text}": line.text, "{caption}": VideoScript.caption(for: line.speaker, among: speakers),
                          "{output}": piece.path, "{seed}": String(VideoScript.seed(seed, speaker: line.speaker, among: speakers))]
            if await runVoice(command, values), FileManager.default.fileExists(atPath: piece.path) { pieces.append(piece) }
        }
        guard !pieces.isEmpty else { return nil }
        let joined = Self.imageFolder.appendingPathComponent("\(name)-script-voice.m4a")
        return await Self.join(pieces, pause: 0.35, into: joined) ? joined : nil
    }

    /// Sound files one after another with `pause` seconds of silence between them, written as .m4a.
    nonisolated static func join(_ files: [URL], pause: Double, into output: URL) async -> Bool {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
        var at = CMTime.zero
        let gap = CMTime(seconds: pause, preferredTimescale: 48_000)
        for (index, file) in files.enumerated() {
            let asset = AVURLAsset(url: file)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration) else { continue }
            if index > 0 { track.insertEmptyTimeRange(CMTimeRange(start: at, duration: gap)); at = at + gap }
            try? track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: at)
            at = at + duration
        }
        try? FileManager.default.removeItem(at: output)
        guard at > .zero, let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return false }
        do { try await export.export(to: output, as: .m4a) } catch { return false }
        return FileManager.default.fileExists(atPath: output.path)
    }

    nonisolated static func seconds(of file: URL) async -> Double? {
        guard let duration = try? await AVURLAsset(url: file).load(.duration) else { return nil }
        let value = duration.seconds
        return value.isFinite && value > 0 ? value : nil
    }
}
