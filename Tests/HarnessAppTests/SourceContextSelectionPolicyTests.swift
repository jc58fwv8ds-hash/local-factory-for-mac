import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

struct SourceContextSelectionPolicyTests {
    @Test func responseRevisionOmitsSourceAfterRemovingNoChangeConstraint() throws {
        let project = project("今の返答を、難しい言葉なしの2文で言い直してちょ。まだファイルは変えないでね。")
        let source = snapshot()

        let selection = SourceContextSelectionPolicy.select(source, for: project)

        #expect(selection.strategy == .omittedForResponseRevision)
        #expect(selection.snapshot == nil)
        #expect(selection.originalFileCount == source.files.count)
        #expect(selection.originalCharacterCount == source.totalCharacters)
    }

    @Test func responseQuestionThatNeedsCodeKeepsAllSource() {
        let source = snapshot()
        let selection = SourceContextSelectionPolicy.select(
            source,
            for: project("今の返答が実装と合うか、コードを確認して教えて")
        )

        #expect(selection.strategy == .allAvailable)
        #expect(selection.snapshot == source)
    }

    @Test func responseRevisionNamingARealFileUsesFocusedSource() throws {
        let selection = SourceContextSelectionPolicy.select(
            snapshot(),
            for: project("今のContentView.swiftの説明を2文で言い直して")
        )

        #expect(selection.strategy == .focused)
        #expect(try #require(selection.snapshot).files.map(\.relativePath) == [
            "PersonalMemory/ContentView.swift",
            "PersonalMemoryTests/ContentViewTests.swift"
        ])
    }

    @Test func ordinaryAndContinuationInstructionsKeepAllSource() {
        let source = snapshot()
        for instruction in ["記憶の安全な保存方法を考えて", "制作を継続"] {
            let selection = SourceContextSelectionPolicy.select(source, for: project(instruction))
            #expect(selection.strategy == .allAvailable)
            #expect(selection.snapshot == source)
        }
    }

    @Test func explicitFileNameFocusesOnItsReferencesWithoutReordering() throws {
        let source = snapshot()
        let selection = SourceContextSelectionPolicy.select(
            source,
            for: project("ContentView.swiftとContentViewを使うテストの役割を教えて")
        )
        let narrowed = try #require(selection.snapshot)

        #expect(selection.strategy == .focused)
        #expect(narrowed.files.map(\.relativePath) == [
            "PersonalMemory/ContentView.swift",
            "PersonalMemoryTests/ContentViewTests.swift"
        ])
        #expect(narrowed.totalCharacters == narrowed.files.reduce(0) { $0 + $1.content.count })
        #expect(narrowed.wasTruncated)
        #expect(narrowed.skippedCandidateCount == source.files.count - narrowed.files.count)
    }

    @Test func unknownOrGenericEnglishWordsFallBackToAllSource() {
        let source = snapshot()
        for instruction in ["UnknownScreen.swiftを説明して", "HarnessのSwift viewを説明して"] {
            let selection = SourceContextSelectionPolicy.select(source, for: project(instruction))
            #expect(selection.strategy == .allAvailable)
            #expect(selection.snapshot == source)
        }
    }

    @Test func workflowExplainsFocusedAndOmittedSelectionWithoutClaimingVerification() throws {
        let source = snapshot()
        var focusedProject = project("ContentView.swiftを説明して")
        let focused = SourceContextSelectionPolicy.select(source, for: focusedProject)
        ProjectInferenceWorkflow.preparedSourceContext(focused, in: &focusedProject)
        #expect(focusedProject.activity.first?.detail.contains("4ファイルから2ファイルを優先") == true)

        var omittedProject = project("今の説明を短く言い直して。まだファイルは変えないでね")
        let omitted = SourceContextSelectionPolicy.select(source, for: omittedProject)
        ProjectInferenceWorkflow.preparedSourceContext(omitted, in: &omittedProject)
        #expect(omittedProject.activity.first?.detail == "返答の言い直しなので、ソース本文はAIへ渡していません")
        #expect(!omittedProject.activity.first!.detail.contains("検証"))
    }

    private func project(_ instruction: String) -> HarnessProject {
        HarnessProject(
            name: "Personal Memory",
            summary: "一日の記憶をまとめるアプリ",
            targets: [.iPhone, .macOS],
            stage: .design,
            progress: 0,
            currentActivity: "相談中",
            workItems: [],
            activity: [],
            conversation: [ConversationMessage(role: .user, content: instruction)]
        )
    }

    private func snapshot() -> SourceContextSnapshot {
        let files = [
            SourceContextFile(relativePath: "README.md", content: "Personal Memoryの説明", wasTruncated: false),
            SourceContextFile(relativePath: "PersonalMemory/ContentView.swift", content: "struct ContentView {}", wasTruncated: false),
            SourceContextFile(relativePath: "PersonalMemory/DesignSystem.swift", content: "enum DesignSystem {}", wasTruncated: false),
            SourceContextFile(relativePath: "PersonalMemoryTests/ContentViewTests.swift", content: "ContentViewを検査する", wasTruncated: false)
        ]
        return SourceContextSnapshot(
            files: files,
            totalCharacters: files.reduce(0) { $0 + $1.content.count },
            wasTruncated: false,
            skippedCandidateCount: 0
        )
    }
}

@MainActor
@Suite(.serialized)
struct SourceContextSelectionIntegrationTests {
    @Test func workspaceUsesTheSelectionBeforeBuildingTheInferenceRequest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Harness-Source-Selection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = WorkspaceRepository(fileURL: directory.appendingPathComponent("workspace.json"))
        let model = ModelSelection(identifier: "fixture", displayName: "Fixture", runtime: .ollama)
        var project = HarnessProject.starter
        project.selectedModel = model
        project.conversation = [
            ConversationMessage(role: .user, content: "待ち時間を説明して"),
            ConversationMessage(role: .assistant, content: "入力を比べる案です", modelName: "Fixture")
        ]
        try repository.saveLibrary(ProjectLibrary(records: [
            ProjectRecord(project: project, sourceLocation: "/fixture")
        ]))
        let inference = SelectionInferenceFixture()
        let source = SelectionSourceFixture()
        let store = WorkspaceStore(
            repository: repository,
            inferenceProvider: inference,
            sourceContextProvider: source
        )

        store.instruction = "今の返答を難しい言葉なしで言い直して。まだファイルは変えないでね"
        store.submitInstruction()
        await store.inferenceTask?.value

        let request = try #require(await inference.requests.last)
        #expect(!request.messages.contains { $0.content.contains("[HARNESS_SOURCE_REFERENCE]") })
        #expect(store.project.activity.contains {
            $0.detail == "返答の言い直しなので、ソース本文はAIへ渡していません"
        })
        #expect(await source.collectionCount == 1)
        #expect(store.project.conversation.last?.content == "短く言い直しました。内容は断定しません。")
    }
}

private actor SelectionSourceFixture: ProjectSourceContextProviding {
    private(set) var collectionCount = 0

    func collect(path: String, budget: SourceContextBudget) async throws -> SourceContextSnapshot {
        collectionCount += 1
        let file = SourceContextFile(
            relativePath: "Sources/Large.swift",
            content: String(repeating: "source", count: 2_000),
            wasTruncated: false
        )
        return SourceContextSnapshot(
            files: [file],
            totalCharacters: file.content.count,
            wasTruncated: false,
            skippedCandidateCount: 0
        )
    }
}

private actor SelectionInferenceFixture: ModelInferenceProvider {
    private(set) var requests: [InferenceRequest] = []

    func events(for request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            continuation.yield("短く言い直しました。内容は断定しません。")
            continuation.finish()
        }
    }
}
