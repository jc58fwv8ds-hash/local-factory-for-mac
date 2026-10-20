import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

/// Chat and code modes (2026-10-19): each mode lists its own projects, purposes exist only in chat, and code changes only
/// start in code mode. Records saved before the split are code projects.
@MainActor
@Suite(.serialized)
struct WorkspaceModeTests {
    func makeStore() throws -> (WorkspaceStore, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let repository = WorkspaceRepository(fileURL: base.appendingPathComponent("workspace.json"))
        var project = HarnessProject.starter
        project.selectedModel = ModelSelection(identifier: "fixture", displayName: "Fixture", runtime: .ollama)
        try repository.saveLibrary(ProjectLibrary(records: [ProjectRecord(project: project)]))
        UserDefaults.standard.removeObject(forKey: WorkspaceMode.key)
        let store = WorkspaceStore(repository: repository)
        store.workspaceMode = .code
        return (store, base)
    }

    @Test func oldRecordsAreCodeAndANewChatIsListedOnlyInChatMode() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base); UserDefaults.standard.removeObject(forKey: WorkspaceMode.key) }
        let code = try #require(store.library.selectedRecord)
        #expect(code.kind == nil && code.effectiveKind == .code)
        #expect(store.modeRecords.map(\.id) == [code.id])
        #expect(store.availablePurposes == [.conversation])

        store.switchMode(.chat)
        #expect(store.modeRecords.isEmpty)
        #expect(!store.selectedProjectIsInMode)
        store.startNewChat()
        let chat = try #require(store.library.selectedRecord)
        #expect(chat.effectiveKind == .chat && chat.sourceLocation == nil)
        #expect(chat.project.selectedModel?.identifier == "fixture")
        #expect(store.modeRecords.map(\.id) == [chat.id])
        #expect(store.availablePurposes.contains(.writing) && store.availablePurposes.contains(.image))

        store.composerPurpose = .image
        store.switchMode(.code)
        #expect(store.composerPurpose == .conversation)
        #expect(store.library.selectedProjectID == code.id)
        store.switchMode(.chat)
        #expect(store.library.selectedProjectID == chat.id)   // each mode reopens where it was
    }

    @Test func badgesAndVideoOptionsComeFromTheCatalog() throws {
        let json = #"{"writing": [{"id": "w", "label": "W", "runtime": "Ollama", "model": "m", "badge": "注意"}], "image": [], "#
            + #""video": [{"id": "v", "label": "V", "command": ["tool", "{prompt}", "{output}"]}]}"#
        let catalog = try JSONDecoder().decode(PurposeModelCatalog.self, from: Data(json.utf8))
        #expect(catalog.options(for: .writing).first?.badge == "注意")
        #expect(catalog.options(for: .video).map(\.id) == ["v"])
        let old = try JSONDecoder().decode(PurposeModelCatalog.self, from: Data(#"{"writing": [], "image": []}"#.utf8))
        #expect(old.options(for: .video).isEmpty)
    }
}
