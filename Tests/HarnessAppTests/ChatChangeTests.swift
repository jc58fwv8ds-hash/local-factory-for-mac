import Foundation
import HarnessCore
import HarnessExecution
import Testing
@testable import HarnessApp

@MainActor
@Suite(.serialized)
struct ChatChangeTests {
    nonisolated static let source = "public enum Meter {\n    public static func level(_ v: Int) -> Int { v }\n}\n"

    actor FakeRun: OrchestratedEditing {
        private(set) var instructions: [String] = []
        func proposeEdit(rootPath: String, relativePath: String, instruction: String,
                         model: ModelSelection) async throws -> OrchestratedEditOutcome {
            instructions.append(instruction)
            return .init(changes: [
                .init(relativePath: "Sources/Meter/Meter.swift", original: ChatChangeTests.source,
                      proposed: ChatChangeTests.source.replacingOccurrences(of: "{ v }", with: "{ min(v, 10) }")),
                .init(relativePath: "Sources/Meter/Limits.swift", original: nil, proposed: "enum Limits { static let level = 10 }\n")
            ], runRecord: URL(fileURLWithPath: "/dev/null"), testsPassedResult: "HARNESS_PASS",
               harnessResult: RequirementVerification.pendingResult)
        }
    }

    func makeStore() throws -> (WorkspaceStore, URL, FakeRun) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("chat-change-\(UUID().uuidString)")
        let package = base.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Sources/Meter"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Meter\", targets: [.target(name: \"Meter\")])\n"
            .write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.source.write(to: package.appendingPathComponent("Sources/Meter/Meter.swift"), atomically: true, encoding: .utf8)
        let repository = WorkspaceRepository(fileURL: base.appendingPathComponent("workspace.json"))
        var project = HarnessProject.starter
        project.selectedModel = ModelSelection(identifier: "fixture", displayName: "Fixture", runtime: .ollama)
        try repository.saveLibrary(ProjectLibrary(records: [ProjectRecord(project: project, sourceLocation: package.path)]))
        let store = WorkspaceStore(repository: repository)
        let fake = FakeRun()
        store.chatOrchestratorOverride = fake
        return (store, package, fake)
    }

    func waitForProposal(_ store: WorkspaceStore) async throws -> ChatChange {
        for _ in 0..<200 {
            if let change = store.chatChanges.values.first(where: { $0.status != .running && $0.status != .discarded }) { return change }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    @Test func changeRequestBecomesACardAndAppliesAndRevertsAllFiles() async throws {
        let (store, package, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        store.instruction = "レベルは10を上限にして直して"
        store.submitInstruction()
        #expect(store.instruction.isEmpty)
        let change = try await waitForProposal(store)
        #expect(change.status == .ready)
        #expect(change.proposals.map(\.relativePath) == ["Sources/Meter/Meter.swift", "Sources/Meter/Limits.swift"])
        #expect(store.project.conversation.first?.content == "レベルは10を上限にして直して")
        #expect(try String(contentsOf: package.appendingPathComponent("Sources/Meter/Meter.swift"), encoding: .utf8) == Self.source)

        await store.applyChatChange(change)
        #expect(change.status == .applied)
        #expect(try String(contentsOf: package.appendingPathComponent("Sources/Meter/Meter.swift"), encoding: .utf8).contains("min(v, 10)"))
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("Sources/Meter/Limits.swift").path))

        await store.revertChatChange(change)
        #expect(change.status == .ready)
        #expect(try String(contentsOf: package.appendingPathComponent("Sources/Meter/Meter.swift"), encoding: .utf8) == Self.source)
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("Sources/Meter/Limits.swift").path))
    }

    /// A file edited after 適用 cannot be reverted safely: 取り消す must not say the project is back, must keep the card
    /// applied, and a second 取り消す reverts only that file (2026-10-12 review: a failed revert was reported as done).
    @Test func aRevertThatFailsIsReportedAndCanBeRetried() async throws {
        let (store, package, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        store.instruction = "レベルは10を上限にして直して"
        store.submitInstruction()
        let change = try await waitForProposal(store)
        await store.applyChatChange(change)
        let meter = package.appendingPathComponent("Sources/Meter/Meter.swift")
        let applied = try String(contentsOf: meter, encoding: .utf8)
        try (applied + "// 手で足した行\n").write(to: meter, atomically: true, encoding: .utf8)

        await store.revertChatChange(change)
        #expect(change.status == .applied)
        #expect(change.applied.map(\.0.relativePath) == ["Sources/Meter/Meter.swift"])
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("Sources/Meter/Limits.swift").path))
        let note = try #require(store.project.conversation.last?.content)
        #expect(note.contains("元に戻せませんでした") && note.contains("Sources/Meter/Meter.swift") && !note.contains("修正前の状態です"))

        try applied.write(to: meter, atomically: true, encoding: .utf8)   // the user takes the hand edit back out
        await store.revertChatChange(change)
        #expect(change.status == .ready)
        #expect(try String(contentsOf: meter, encoding: .utf8) == Self.source)
        #expect(store.project.conversation.last?.content.contains("修正前の状態です") == true)
    }

    @Test func followUpRefinesThePendingProposalWithBothInstructions() async throws {
        let (store, package, fake) = try makeStore()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        store.instruction = "上限を10にして"
        store.submitInstruction()
        let first = try await waitForProposal(store)
        store.instruction = "マイナスは0にして"
        store.submitInstruction()
        #expect(first.status == .discarded)
        _ = try await waitForProposal(store)
        let sent = await fake.instructions
        #expect(sent.last?.contains("上限を10にして") == true && sent.last?.contains("追加の指示: マイナスは0にして") == true)
    }

    /// Backlog #12: a correction chosen after 違う becomes a convention of the project and goes with later instructions.
    @Test func aChosenAlternativeIsRememberedAndSentWithTheNextInstruction() async throws {
        let (store, package, fake) = try makeStore()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        store.instruction = "5000円以上は送料無料にして"
        store.submitInstruction()
        let first = try await waitForProposal(store)
        let example = ChatExample(situation: "合計がちょうど5000円", quantity: "送料(円)", after: "0", before: "500",
                                  alternatives: ["5000円を超えたら無料にする"])
        first.examples = [example]
        store.answerExample(example, in: first, .wrong)
        #expect(store.chooseAlternative("5000円を超えたら無料にする", for: example))
        #expect(store.project.conventions == ["「合計がちょうど5000円」のとき: 5000円を超えたら無料にする"])
        store.rememberConvention("x"); store.forgetConvention("x")
        #expect(store.project.conventions?.count == 1)
        let second = try await waitForProposal(store)
        store.discardChatChange(second)
        store.instruction = "送料の表示を右寄せにして"
        store.submitInstruction()
        _ = try await waitForProposal(store)
        let sent = await fake.instructions
        #expect(sent.last?.contains("このプロジェクトでこれまでに確かめた決まり") == true)
        #expect(sent.last?.contains("5000円を超えたら無料にする") == true)
    }

    /// The card comes first; the example check arrives afterwards from postChecks (2026-10-09).
    actor CheckedRun: OrchestratedEditing {
        let folder: URL
        init(folder: URL) { self.folder = folder }
        func proposeEdit(rootPath: String, relativePath: String, instruction: String,
                         model: ModelSelection) async throws -> OrchestratedEditOutcome {
            let record = folder.appendingPathComponent("first.json")
            try JSONSerialization.data(withJSONObject: ["modelFirstPass": "MODEL_FIRST_PASS_FAIL"]).write(to: record)
            let context = PostCheckContext(candidate: folder, root: folder, output: folder, model: "m", objective: instruction, originals: [:])
            return .init(changes: [.init(relativePath: "Sources/Meter/Meter.swift", original: ChatChangeTests.source,
                                         proposed: ChatChangeTests.source.replacingOccurrences(of: "{ v }", with: "{ min(v, 10) }"))],
                         runRecord: record, testsPassedResult: "HARNESS_PASS", harnessResult: RequirementVerification.pendingResult,
                         postCheck: context)
        }
        func postChecks(_ context: PostCheckContext) async -> URL? {
            try? await Task.sleep(for: .milliseconds(150))
            let record = folder.appendingPathComponent("checked.json")
            let row: [String: Any] = ["situation": "値が11", "quantity": "レベル", "after": "10", "alternatives": [String]()]
            try? JSONSerialization.data(withJSONObject: ["modelFirstPass": "MODEL_FIRST_PASS_FAIL",
                                                         "exampleCheck": ["outcome": "shown", "examples": [row]]]).write(to: record)
            return record
        }
    }

    @Test func theCardComesFirstAndTheExamplesArriveAfterwards() async throws {
        let (store, package, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        store.chatOrchestratorOverride = CheckedRun(folder: package.deletingLastPathComponent())
        store.instruction = "上限を10にして"
        store.submitInstruction()
        let change = try await waitForProposal(store)
        #expect(change.status == .ready && change.isChecking && change.examples.isEmpty)
        for _ in 0..<100 where change.isChecking { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!change.isChecking && change.examples.first?.after == "10")
    }

    /// Backlog #39: a case answered 違う goes to the follow-up's checks, and the verified test file joins its proposal.
    actor AgreedRun: OrchestratedEditing {
        let folder: URL
        private(set) var seedsSeen: [[[String: String]]] = []
        init(folder: URL) { self.folder = folder }
        func proposeEdit(rootPath: String, relativePath: String, instruction: String,
                         model: ModelSelection) async throws -> OrchestratedEditOutcome {
            let record = folder.appendingPathComponent("first-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: [String: Any]()).write(to: record)
            return .init(changes: [.init(relativePath: "Sources/Meter/Meter.swift", original: ChatChangeTests.source,
                                         proposed: ChatChangeTests.source.replacingOccurrences(of: "{ v }", with: "{ min(v, 10) }"))],
                         runRecord: record, testsPassedResult: "HARNESS_PASS", harnessResult: RequirementVerification.pendingResult,
                         postCheck: PostCheckContext(candidate: folder, root: folder, output: folder, model: "m",
                                                     objective: instruction, originals: [:]))
        }
        func postChecks(_ context: PostCheckContext) async -> URL? {
            seedsSeen.append(context.seeds)
            let record = folder.appendingPathComponent("checked-\(UUID().uuidString).json")
            let row: [String: Any] = ["situation": "値が11", "quantity": "レベル", "after": "10", "setup": "",
                                      "expression": "Meter.level(11)", "alternatives": ["11 のときは 11 のままにする"]]
            var check: [String: Any] = ["outcome": "shown", "examples": [row]]
            if !context.seeds.isEmpty {
                check["agreedTest"] = ["path": "Tests/MeterTests/LocalFactoryAgreedTests.swift",
                                       "content": "import Testing\n@testable import Meter\n@Test func agreed_1() {}\n"]
            }
            try? JSONSerialization.data(withJSONObject: ["exampleCheck": check]).write(to: record)
            return record
        }
    }

    @Test func aCorrectedCaseBecomesAProtectedTestOfTheFollowUp() async throws {
        let (store, package, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        // A real project has its test target's folder; the agreed tests go next to its tests.
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Tests/MeterTests"), withIntermediateDirectories: true)
        let fake = AgreedRun(folder: package.deletingLastPathComponent())
        store.chatOrchestratorOverride = fake
        store.instruction = "上限を10にして"
        store.submitInstruction()
        let first = try await waitForProposal(store)
        for _ in 0..<100 where first.isChecking || first.examples.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let example = try #require(first.examples.first)
        #expect(example.expression == "Meter.level(11)")
        store.answerExample(example, in: first, .wrong)
        #expect(store.chooseAlternative("11 のときは 11 のままにする", for: example))
        var second: ChatChange?
        for _ in 0..<200 {
            second = store.chatChanges.values.first { $0 !== first && $0.status == .ready && !$0.isChecking }
            if let second, second.proposals.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let followUp = try #require(second)
        #expect(await fake.seedsSeen.last?.first?["expression"] == "Meter.level(11)")
        #expect(followUp.proposals.map(\.relativePath).contains("Tests/MeterTests/LocalFactoryAgreedTests.swift"))
        #expect(followUp.cautions.contains { $0.contains("テスト") })
    }

    @Test func cautionsFollowTheMeasuredRiskSignals() throws {
        let record = FileManager.default.temporaryDirectory.appendingPathComponent("chat-change-record-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: record) }
        try JSONSerialization.data(withJSONObject: ["modelFirstPass": "MODEL_FIRST_PASS_FAIL", "mandatoryClauseCount": 9])
            .write(to: record)
        let cautions = WorkspaceStore.chatChangeCautions(record: record, instruction: "10以上20未満は除く。最初と最後は含める。")
        #expect(cautions.count == 3)
        #expect(WorkspaceStore.chatChangeCautions(record: URL(fileURLWithPath: "/dev/null"), instruction: "色を青にして").isEmpty)
    }

    @Test func examplesComeFromTheRunRecordAndAnAlternativeBecomesAFollowUpInstruction() throws {
        let record = FileManager.default.temporaryDirectory.appendingPathComponent("chat-change-examples-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: record) }
        let row: [String: Any] = ["situation": "合計がちょうど5000円の注文", "quantity": "送料(円)", "after": "0", "before": "500",
                                  "expression": "fee(5000)", "alternatives": ["5000円を超えたら無料にする"]]
        try JSONSerialization.data(withJSONObject: ["exampleCheck": ["outcome": "shown", "examples": [row, ["situation": "欠け"]]]])
            .write(to: record)
        let examples = WorkspaceStore.chatExamples(record: record)
        #expect(examples.count == 1)
        #expect(examples[0].before == "500" && examples[0].after == "0" && examples[0].answer == nil)
        #expect(examples[0].instruction(for: "5000円を超えたら無料にする")
            == "「合計がちょうど5000円の注文」のとき、送料(円)は今の修正では 0 です。5000円を超えたら無料にする")
        #expect(WorkspaceStore.chatExamples(record: URL(fileURLWithPath: "/dev/null")).isEmpty)
    }

    @Test func onlyChangeWordsRouteToACodeChange() {
        #expect(PrimaryInstructionIntentRouter.isCodeChangeRequest("合計の行を直して"))
        #expect(PrimaryInstructionIntentRouter.isCodeChangeRequest("マイナスは赤字にして"))
        #expect(!PrimaryInstructionIntentRouter.isCodeChangeRequest("このアプリの設計を説明して"))
    }

    @Test func requestLikeSentencesGoToTheSystemModelButQuestionsDoNot() {
        #expect(PrimaryInstructionIntentRouter.mayBeChangeRequest("合計の行が画面に収まるようにしてほしい"))
        #expect(PrimaryInstructionIntentRouter.mayBeChangeRequest("ダークモードにも対応したい"))
        #expect(!PrimaryInstructionIntentRouter.mayBeChangeRequest("このコードは何をしてる？"))
        #expect(!PrimaryInstructionIntentRouter.mayBeChangeRequest("設計の考え方を説明して"))
    }

    /// Calls the real on-device model (HARNESS_SYSTEM_MODEL_LIVE=1).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_SYSTEM_MODEL_LIVE"] == "1"))
    func systemModelSeparatesChangesFromQuestions() async throws {
        SystemIntentClassifier.prewarm()
        try await Task.sleep(for: .seconds(5))
        #expect(await SystemIntentClassifier.isCodeChange("合計の行が右にはみ出しているので、画面に収まるようにしてほしい") == true)
        #expect(await SystemIntentClassifier.isCodeChange("このアプリの設計方針について相談したい") == false)
    }
}
