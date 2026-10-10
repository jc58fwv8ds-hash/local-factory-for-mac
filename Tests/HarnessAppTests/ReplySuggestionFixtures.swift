import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

enum ReplySuggestionFixtures {
    static let json = """
    {"suggestions":[
    {"title":"今できることを知る","instruction":"まず今できることを短く教えて。まだ変えないでね。","effect":"作る必要がある部分を分けて考えやすくなるよ。"},
    {"title":"案の違いを比べる","instruction":"2つの案の違いを、難しい言葉なしで教えてちょ。","effect":"どちらが自分に合いそうか考えやすくなるよ。"}]}
    """

    static func project() -> HarnessProject {
        var project = HarnessProject(name: "候補のテスト", summary: "保存の案を相談", targets: [.macOS],
                                     stage: .design, progress: 0.2, currentActivity: "設計中", workItems: [], activity: [])
        project.selectedModel = ModelSelection(identifier: "fixture", displayName: "Fixture", runtime: .ollama)
        project.conversation = [
            ConversationMessage(role: .user, content: "案を教えてちょ。まだファイルは変えないでね。"),
            ConversationMessage(role: .assistant, content: "最初は保存の流れを確認する案と、画面の使い方を考える案があるよ。")
        ]
        return project
    }

    static func waitForRequest(_ provider: ReplySuggestionInferenceFixture) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await provider.requests.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await !provider.requests.isEmpty)
    }
}

actor ReplySuggestionInferenceFixture: ModelInferenceProvider {
    private(set) var requests: [InferenceRequest] = []
    let json: String
    let holdSuggestions: Bool
    private var held: AsyncThrowingStream<String, Error>.Continuation?

    init(json: String = ReplySuggestionFixtures.json, holdSuggestions: Bool = false) {
        self.json = json
        self.holdSuggestions = holdSuggestions
    }

    func events(for request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        let stream = AsyncThrowingStream<String, Error>.makeStream()
        let isSuggestion = request.structuredOutput == .replySuggestions
        stream.continuation.yield(isSuggestion ? json : "まだ変更せず、案の違いを説明するね。")
        if isSuggestion && holdSuggestions {
            held = stream.continuation
        } else {
            stream.continuation.finish()
        }
        return stream.stream
    }
}

@MainActor
struct ReplySuggestionStoreFixture {
    let directory: URL
    let repository: WorkspaceRepository
    let provider: ReplySuggestionInferenceFixture
    let store: WorkspaceStore

    init(holdSuggestions: Bool = false, json: String = ReplySuggestionFixtures.json) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Harness-Reply-\(UUID().uuidString)")
        repository = WorkspaceRepository(fileURL: directory.appendingPathComponent("workspace.json"))
        provider = ReplySuggestionInferenceFixture(json: json, holdSuggestions: holdSuggestions)
        try repository.saveLibrary(ProjectLibrary(records: [ProjectRecord(project: ReplySuggestionFixtures.project())]))
        store = WorkspaceStore(repository: repository, inferenceProvider: provider)
    }

    func removeFiles() { try? FileManager.default.removeItem(at: directory) }
}
