import Foundation
import HarnessCore
import Testing
@testable import HarnessExecution

/// Synthetic, task-independent checks for Readable Context != Editable Scope,
/// Missing-Context Escalation, and repair scope.
struct ContextScopeSplitTests {
    let files: [String: String] = [
        "Sources/Trip/Itinerary.swift": "struct Itinerary { var stops: [Stop] = []; func total() -> Int { stops.count } }",
        "Sources/Trip/Stop.swift": "struct Stop { let name: String; let minutes: Int }",
        "Sources/Trip/StopCache.swift": "struct StopCache { var items: [Stop] = [] }",
        "Sources/Trip/Weather.swift": "struct Weather { let celsius: Int }",
        "Sources/Trip/Quota.swift": "enum Quota { static func ok(_ n: Int) -> Bool { n <= 250_000 } }",
        "Sources/Trip/Uploader.swift": "struct Uploader { func send(_ n: Int) -> Bool { n <= 250_000 } }"
    ]
    func select(_ objective: String, order: [String]? = nil) -> ContextSelector.Selection {
        let paths = order ?? files.keys.sorted()
        return ContextSelector.select(objective: objective, paths: paths,
            evidence: paths.map { .init(path: $0, source: files[$0]!) })
    }
    func request(_ file: String?, _ symbol: String?, _ op: String) -> StructuredEditBatch.ContextRequest {
        .init(file: file, symbol: symbol, why_needed: "need it", relation: "dependency", operation: op)
    }

    @Test func evidenceIsReadableButNotEditableAndTargetIsEditable() {
        let s = select("Itinerary に合計所要時間を返すメソッドを追加して")
        #expect(s.targets == ["Sources/Trip/Itinerary.swift"])
        #expect(s.evidence == ["Sources/Trip/Stop.swift"])
        #expect(s.files == s.targets + s.evidence)
        let stop = s.entries.first { $0.path == "Sources/Trip/Stop.swift" }!
        #expect(stop.role == .evidence && !stop.editable && stop.relation.contains("Stop"))
        #expect(s.entries.first { $0.path == "Sources/Trip/Itinerary.swift" }!.editable)
        #expect(!s.files.contains("Sources/Trip/StopCache.swift") && !s.files.contains("Sources/Trip/Weather.swift"))
    }

    @Test func selectionIsDeterministicAcrossInputOrder() {
        let objective = "Quota の上限250,000を定数にして送信側でも使って"
        let a = select(objective), b = select(objective, order: files.keys.sorted().reversed())
        #expect(a.entries == b.entries && a.files == b.files)
    }

    @Test func requestedDependencyIsAddedAndPromotedOnlyWithEditIntent() {
        let targets = ["Sources/Trip/Itinerary.swift"]
        let edit = ContextEscalation.evaluate(request(nil, "Stop", "edit"), objective: "Itinerary を変更",
            targets: targets, contextSet: targets, sources: files, protected: [])
        #expect(edit.accepted && edit.addToContext == ["Sources/Trip/Stop.swift"] && edit.promoteToEditable == ["Sources/Trip/Stop.swift"])
        let read = ContextEscalation.evaluate(request("Sources/Trip/Stop.swift", nil, "read"), objective: "Itinerary を変更",
            targets: targets, contextSet: targets, sources: files, protected: [])
        #expect(read.accepted && read.addToContext == ["Sources/Trip/Stop.swift"] && read.promoteToEditable.isEmpty)
    }

    @Test func missingSymbolUnrelatedFileAndWeakRelationAreRejected() {
        let targets = ["Sources/Trip/Itinerary.swift"]
        let missing = ContextEscalation.evaluate(request(nil, "Hotel", "edit"), objective: "x",
            targets: targets, contextSet: targets, sources: files, protected: [])
        #expect(!missing.accepted && missing.rejection == "fileOrSymbolNotFound")
        let invented = ContextEscalation.evaluate(request("Sources/Trip/Hotel.swift", nil, "edit"), objective: "x",
            targets: targets, contextSet: targets, sources: files, protected: [])
        #expect(!invented.accepted && invented.rejection == "fileOrSymbolNotFound")
        let unrelated = ContextEscalation.evaluate(request("Sources/Trip/Weather.swift", nil, "edit"), objective: "x",
            targets: targets, contextSet: targets, sources: files, protected: [])
        #expect(!unrelated.accepted && unrelated.rejection == "noRelationEvidence")
        // StopCache only *uses* Stop; with Stop as target that is not an edit rationale.
        let weak = ContextEscalation.evaluate(request("Sources/Trip/StopCache.swift", nil, "edit"), objective: "x",
            targets: ["Sources/Trip/Stop.swift"], contextSet: ["Sources/Trip/Stop.swift"], sources: files, protected: [])
        #expect(!weak.accepted && weak.rejection == "insufficientEditRationale" && weak.promoteToEditable.isEmpty)
        let test = ContextEscalation.evaluate(request("Tests/TripTests/Acceptance.swift", nil, "read"), objective: "x",
            targets: targets, contextSet: targets, sources: files, protected: ["Tests/TripTests/Acceptance.swift"])
        #expect(!test.accepted && test.rejection == "protectedOrTest")
    }

    @Test func sharedConstraintValueGivesEditRationale() {
        let d = ContextEscalation.evaluate(request("Sources/Trip/Uploader.swift", nil, "edit"),
            objective: "上限250,000を共有して", targets: ["Sources/Trip/Quota.swift"],
            contextSet: ["Sources/Trip/Quota.swift"], sources: files, protected: [])
        #expect(d.accepted && d.promoteToEditable == ["Sources/Trip/Uploader.swift"])
    }

    @Test func escalationIsAllowedOnlyOncePerTask() {
        #expect(ContextEscalation.admit(escalationsUsed: 0))
        #expect(!ContextEscalation.admit(escalationsUsed: 1))
    }

    @Test func implicitRequestOnlyForExistingNonEditablePaths() throws {
        let invented = try JSONDecoder().decode(StructuredEditBatch.self, from: Data("""
        {"edits":[{"operation":"replace_exact","file":"Sources/Trip/Hotel.swift","expected_old_text":"a","new_text":"b"}]}
        """.utf8))
        #expect(ContextEscalation.implicitRequest(fromEditsIn: invented, editable: ["Sources/Trip/Itinerary.swift"], sources: files) == nil)
        let readOnly = try JSONDecoder().decode(StructuredEditBatch.self, from: Data("""
        {"edits":[{"operation":"replace_exact","file":"Sources/Trip/Stop.swift","expected_old_text":"a","new_text":"b"}]}
        """.utf8))
        #expect(ContextEscalation.implicitRequest(fromEditsIn: readOnly, editable: ["Sources/Trip/Itinerary.swift"], sources: files)?.file == "Sources/Trip/Stop.swift")
    }

    @Test func contextRequestDecodesWithoutEditsAndIsNeverAnEdit() throws {
        let batch = try JSONDecoder().decode(StructuredEditBatch.self, from: Data("""
        {"context_request":{"file":"","symbol":"Stop","why_needed":"field needed","relation":"type of stops","operation":"edit"}}
        """.utf8))
        #expect(batch.edits.isEmpty && batch.context_request?.symbol == "Stop")
        #expect(throws: (any Error).self) {
            try batch.proposedContents(originals: ["a": "x"], protected: [], appendOnly: [], maxEdits: 2, maxLines: 5)
        }
    }

    @Test func repairNeverWidensEditableTargets() {
        func d(_ p: String) -> CompilerRepair.Diagnostic { .init(path: p, line: 1, column: 1, message: "cannot convert") }
        let editable: Set<String> = ["Sources/Trip/Quota.swift"]
        #expect(CompilerRepair.eligibility([d("Sources/Trip/Uploader.swift")], permitted: editable, protected: [],
            readOnly: ["Sources/Trip/Uploader.swift"]) == .readOnlyEvidenceDiagnostic)
        #expect(CompilerRepair.repairFiles(diagnostics: [d("Sources/Trip/Uploader.swift"), d("Sources/Trip/Quota.swift")],
            firstPass: ["Sources/Trip/Quota.swift"], editable: editable) == ["Sources/Trip/Quota.swift"])
    }
}
