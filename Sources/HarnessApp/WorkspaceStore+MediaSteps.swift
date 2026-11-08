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
        let request = InferenceRequest(runtime: writer.runtime, modelIdentifier: writer.identifier, messages: [
            InferenceMessage(role: .user, content: PictureCheck.request(prompt: prompt))
        ], maximumOutputTokens: 120, images: await ComputerUseScreenshot.inferenceImages(data), temperature: 0)
        var reply = ""
        do {
            for try await piece in await inferenceProvider.events(for: request) { reply += piece }
        } catch { reply = "" }
        if PictureCheck.passed(reply) { return true }
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.removeItem(at: GeneratedMedia.stepsFolder(of: output))
        return false
    }
}
