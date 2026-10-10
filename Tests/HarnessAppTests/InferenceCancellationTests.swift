import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

@MainActor
@Suite(.serialized)
struct InferenceCancellationTests {
    private let model = ModelSelection(identifier: "fixture", displayName: "Fixture", runtime: .ollama)

    @Test(arguments: ["", "途中までの返答"])
    func stoppedConversationNeverPersistsAPartialAnswer(fragment: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = WorkspaceRepository(fileURL: directory.appendingPathComponent("workspace.json"))
        var project = HarnessProject.starter
        project.selectedModel = model
        try repository.saveLibrary(ProjectLibrary(records: [ProjectRecord(project: project)]))
        let provider = HeldInferenceFixture(fragment: fragment)
        let store = WorkspaceStore(repository: repository, inferenceProvider: provider)
        store.instruction = "続けて"
        store.submitInstruction()
        try await waitUntil { await provider.requestCount == 1 && store.streamingResponse == fragment }
        store.stopGeneration()
        await store.inferenceTask?.value
        #expect(store.project.conversation.map(\.role) == [.user])
        #expect(store.project.workItems.first?.status == .needsAttention)
        #expect(store.project.operationCheckpoint?.operation == .modelInference)
        #expect(store.streamingResponse.isEmpty)
        #expect(!store.isGenerating)
        #expect(store.lastConversationPerformance == nil && store.generationTimings.isEmpty)
        #expect(try repository.loadLibrary()?.selectedRecord?.project == store.project)
        store.instruction = "続けてちょ"
        store.submitInstruction()
        #expect(store.instruction == "続けてちょ")
        #expect(await provider.requestCount == 1)
    }

    @Test func stoppedComputerPlanDoesNotPublishEvenValidBufferedJSON() async throws {
        let provider = HeldInferenceFixture(fragment:
            #"{"summary":"テストします","steps":[{"kind":"projectValidation","query":null,"application":null,"element":null,"reason":"確認"}]}"#)
        let session = ComputerOperatorSession(inferenceProvider: provider, validationProvider: LocalProjectValidationService())
        var checkpointCount = 0
        session.configureCheckpointPersistence { _, _ in checkpointCount += 1 }
        var project = HarnessProject.starter
        project.selectedModel = model
        session.instruction = "テストして"
        session.makePlan(project: project, rootPath: "/fixture")
        try await receivedFragment(provider)
        session.stop()
        try await waitUntil { !session.isBusy }
        #expect(session.plan == nil)
        #expect(checkpointCount == 0)
        #expect(session.errorMessage?.contains("停止") == true)
    }

    @Test func stoppedArtifactPlanReportsCancellationRatherThanReady() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = HeldInferenceFixture(fragment:
            #"{"files":[{"path":"One.swift","instruction":"型を定義"},{"path":"Two.swift","instruction":"別の型を定義"}]}"#)
        var didCancel = false
        var didBecomeReady = false
        let session = ArtifactPlanSession(
            rootPath: directory.path, model: model, editor: ProjectFileEditor(), inferenceProvider: provider
        ) { event in
            if case .cancelled = event { didCancel = true }
            if case .planReady = event { didBecomeReady = true }
        }
        session.instruction = "型を2つに分けて"
        session.generate(existingPaths: [])
        try await receivedFragment(provider)
        session.stop()
        try await waitUntil { !session.isGenerating }
        #expect(session.plan == nil)
        #expect(didCancel && !didBecomeReady)
    }

    @Test func stoppedReplanDoesNotPublishACompleteBufferedProposal() async throws {
        let provider = HeldInferenceFixture(fragment:
            #"{"summary":"順序を維持します","uncertainties":[],"items":[{"reference":"item-1","title":"確認","detail":"検査する"}]}"#)
        let session = WorkPlanReplanSession(model: model, inference: provider)
        let item = WorkItem(title: "確認", detail: "検査する", status: .active)
        let project = HarnessProject(
            name: "取消テスト", summary: "", targets: [.macOS], stage: .test,
            progress: 0.5, currentActivity: "失敗", workItems: [item], activity: [],
            selectedModel: model,
            runCoordinator: RunCoordinatorState(
                phase: .awaitingRepair,
                currentWorkItemID: item.id,
                attemptedCycleCount: 1
            )
        )
        let report = ProjectValidationReport(
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            checks: [
                ProjectValidationCheck(
                    kind: .test, succeeded: false, exitCode: 1,
                    output: "failed", outputWasTruncated: false, duration: 1
                )
            ]
        )

        session.generate(project: project, report: report, analysis: nil)
        try await receivedFragment(provider)
        session.stop()
        try await waitUntil { !session.isGenerating }
        try await Task.sleep(for: .milliseconds(80))

        #expect(session.proposal == nil)
    }

    @Test func stoppedFileProposalDoesNotExposeCancelledContent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = ProjectFileEditor()
        let provider = HeldInferenceFixture(fragment: #"{"content":"struct CancelledProposal {}"}"#)
        var didCancel = false
        var didBecomeReady = false
        let session = FileChangeSession(
            rootPath: directory.path, model: model, editor: editor,
            gitCheckpointProvider: GitCheckpointService(fileEditor: editor), inferenceProvider: provider,
            validationProvider: LocalProjectValidationService()
        ) { event in
            if case .cancelled = event { didCancel = true }
            if case .proposalReady = event { didBecomeReady = true }
        }
        session.isCreatingNewFile = true
        session.newFileRelativePath = "Cancelled.swift"
        session.aiInstruction = "型を作って"
        session.askAI()
        try await receivedFragment(provider)
        session.stopAI()
        await session.generationTask?.value
        #expect(session.proposal == nil)
        #expect(session.proposedContent.isEmpty)
        #expect(didCancel && !didBecomeReady)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Cancelled.swift").path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Harness-Cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func receivedFragment(_ provider: HeldInferenceFixture) async throws {
        try await waitUntil { await provider.requestCount == 1 }
        try await Task.sleep(for: .milliseconds(30))
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await predicate())
    }
}

private actor HeldInferenceFixture: ModelInferenceProvider {
    let fragment: String
    private(set) var requestCount = 0
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    init(fragment: String) { self.fragment = fragment }

    func events(for request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        requestCount += 1
        let stream = AsyncThrowingStream<String, Error>.makeStream()
        continuation = stream.continuation
        if !fragment.isEmpty { stream.continuation.yield(fragment) }
        return stream.stream
    }
}
