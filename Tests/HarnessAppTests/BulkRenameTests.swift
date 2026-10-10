import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

/// File operations stage 2 (2026-10-09): the model writes a rule; the app expands, checks, applies and undoes it.
struct BulkRenameTests {
    let day = { (d: Int) in Date(timeIntervalSince1970: 1_790_000_000 + Double(d) * 86_400) }

    @Test func aRuleIsExpandedInOrderWithNumbersDatesAndTheExtensionKept() {
        let files = [RenameFile(name: "IMG_0002.JPG", created: day(1), modified: day(1)),
                     RenameFile(name: "IMG_0001.JPG", created: day(0), modified: day(0)),
                     RenameFile(name: "memo.txt", created: day(0), modified: day(0))]
        let plan = BulkRename.plan(RenameRule(extensions: ["jpg"], order: "created", template: "旅行_{created:yyyyMMdd}_{n:3}"),
                                   files: files, folderName: "写真")
        #expect(plan.matched == 2 && plan.canApply)
        #expect(plan.items.map(\.from) == ["IMG_0001.JPG", "IMG_0002.JPG"])
        #expect(plan.items[0].to.hasPrefix("旅行_") && plan.items[0].to.hasSuffix("_001.JPG"))
        #expect(plan.items[1].to.hasSuffix("_002.JPG"))
    }

    @Test func findAndReplaceWorksOnTheBaseNameAndUnchangedFilesAreLeftOut() {
        let files = [RenameFile(name: "報告書 (1).docx", created: day(0), modified: day(0)),
                     RenameFile(name: "報告書.docx", created: day(0), modified: day(0))]
        let plan = BulkRename.plan(RenameRule(find: #" \((\d+)\)$"#, replace: "_v$1", template: "{name}"), files: files, folderName: "")
        #expect(plan.items == [.init(from: "報告書 (1).docx", to: "報告書_v1.docx")])
    }

    @Test func collisionsAndInvalidNamesStopThePlan() {
        let files = [RenameFile(name: "a.txt", created: day(0), modified: day(0)),
                     RenameFile(name: "b.txt", created: day(0), modified: day(0)),
                     RenameFile(name: "same.txt", created: day(0), modified: day(0))]
        let toOne = BulkRename.plan(RenameRule(extensions: ["txt"], nameContains: "a", template: "same"), files: files, folderName: "")
        #expect(!toOne.canApply && toOne.problems.first?.contains("すでにあるファイル") == true)
        let both = BulkRename.plan(RenameRule(template: "x"), files: Array(files.prefix(2)), folderName: "")
        #expect(both.problems.first?.contains("同じ名前") == true)
        let slash = BulkRename.plan(RenameRule(template: "a/b"), files: [files[0]], folderName: "")
        #expect(slash.problems.first?.contains("使えません") == true)
    }

    @Test func applyingRenamesSwapsSafelyAndUndoRestoresEverything() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "A".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "B".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let swap = [RenamePlan.Item(from: "a.txt", to: "b.txt"), RenamePlan.Item(from: "b.txt", to: "a.txt")]
        try BulkRenameExecutor.apply(swap, in: folder)
        #expect(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8) == "B")
        try BulkRenameExecutor.undo(swap, in: folder)
        #expect(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8) == "A")
        #expect(try BulkRenameExecutor.files(in: folder).map(\.name).sorted() == ["a.txt", "b.txt"])
        // A plan made before the folder changed is refused without touching anything.
        #expect(throws: BulkRenameExecutor.Failure.self) {
            try BulkRenameExecutor.apply([.init(from: "gone.txt", to: "c.txt")], in: folder)
        }
    }
}

/// The chat flow: a folder is attached, "連番にして" becomes a rename card, apply and undo work on the real folder.
@MainActor
struct BulkRenameChatTests {
    struct RuleModel: ModelInferenceProvider {
        let reply: String
        func events(for request: InferenceRequest) async -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.yield(reply); $0.finish() }
        }
    }

    @Test func aRenameRequestBecomesACardThatAppliesAndUndoes() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rename-chat-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("写真")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for name in ["IMG_0001.JPG", "IMG_0002.JPG"] { try Data().write(to: folder.appendingPathComponent(name)) }
        let repository = WorkspaceRepository(fileURL: base.appendingPathComponent("workspace.json"))
        var project = HarnessProject.starter
        project.selectedModel = ModelSelection(identifier: "fixture", displayName: "Fixture", runtime: .ollama)
        try repository.saveLibrary(ProjectLibrary(records: [ProjectRecord(project: project)]))
        let store = WorkspaceStore(repository: repository, inferenceProvider: RuleModel(
            reply: #"規則です: {"extensions": ["jpg"], "order": "name", "template": "旅行_{n:2}", "startNumber": 1}"#))
        #expect(BulkRenameIntent.isRenameRequest("このフォルダの写真を連番にして"))
        #expect(!BulkRenameIntent.isRenameRequest("この写真に写っているのは誰？"))
        store.attachFolder(folder)
        store.instruction = "このフォルダの写真を旅行_01 のような連番にして"
        store.submitInstruction()
        var change: RenameChange?
        for _ in 0..<200 {
            change = store.renameChanges.values.first { $0.status != .running }
            if change != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let ready = try #require(change)
        #expect(ready.plan?.items == [.init(from: "IMG_0001.JPG", to: "旅行_01.JPG"), .init(from: "IMG_0002.JPG", to: "旅行_02.JPG")])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["IMG_0001.JPG", "IMG_0002.JPG"])
        store.applyRenameChange(ready)
        #expect(ready.status == .applied)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["旅行_01.JPG", "旅行_02.JPG"])
        store.revertRenameChange(ready)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["IMG_0001.JPG", "IMG_0002.JPG"])
    }
}
