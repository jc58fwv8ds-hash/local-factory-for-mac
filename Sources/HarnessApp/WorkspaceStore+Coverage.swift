import Foundation
import HarnessCore

extension WorkspaceStore {
    /// The prompt with whatever the user's words asked for and it left out put back (RequestCoverage, 2026-11-14).
    func coveringRequest(_ prompt: String, instruction: String, isVideo: Bool, writer: ModelSelection?, previousPrompt: String? = nil) async -> String {
        let covered = await coveringElements(prompt, instruction: instruction, isVideo: isVideo, writer: writer)
        guard let writer, !Task.isCancelled else { return covered }
        let ask = InferenceRequest(runtime: writer.runtime, modelIdentifier: writer.identifier, messages: [
            InferenceMessage(role: .user, content: RequestCoverage.placeQuestion(instruction: instruction, previousPrompt: previousPrompt))],
            maximumOutputTokens: 80, temperature: 0)
        var reply = ""
        do { for try await piece in await inferenceProvider.events(for: ask) { reply += piece } } catch { return covered }
        return RequestCoverage.placing(reply, in: covered, instruction: instruction)
    }

    private func coveringElements(_ prompt: String, instruction: String, isVideo: Bool, writer: ModelSelection?) async -> String {
        guard let writer, !Task.isCancelled else { return RequestCoverage.droppingOldBackdrop(prompt, instruction: instruction) }
        let request = InferenceRequest(runtime: writer.runtime, modelIdentifier: writer.identifier, messages: [
            InferenceMessage(role: .user, content: RequestCoverage.request(instruction: instruction, prompt: prompt, isVideo: isVideo))],
            maximumOutputTokens: 500, temperature: 0)
        var reply = ""
        do { for try await piece in await inferenceProvider.events(for: request) { reply += piece } } catch { return prompt }
        return RequestCoverage.droppingOldBackdrop(ModelRefusal.looksLikeRefusal(reply) ? prompt : RequestCoverage.apply(reply, to: prompt), instruction: instruction)
    }
}
