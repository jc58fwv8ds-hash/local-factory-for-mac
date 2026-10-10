import Testing
@testable import HarnessExecution

/// Relationship expansion must find behavior-described files through code evidence,
/// stay bounded, and ignore weak or conventional links.
struct ContextRelationshipTests {
    private func select(_ objective: String, _ files: [String: String]) -> ContextSelector.Selection {
        let paths = files.keys.sorted()
        return ContextSelector.select(objective: objective, paths: paths,
            evidence: paths.map { .init(path: $0, source: files[$0]!) })
    }

    @Test func sharedConstraintValueFindsUnnamedSecondFile() {
        let selection = select("添付の上限5,000,000バイトを AttachmentRules の定数にまとめ、検証と送信で共有して", [
            "Sources/Mail/AttachmentRules.swift": "enum AttachmentRules { static func isAllowed(_ n: Int) -> Bool { n <= 5_000_000 } }",
            "Sources/Mail/OutboxUploader.swift": "struct OutboxUploader { func upload(_ size: Int) throws { guard size <= 5_000_000 else { throw E.big } } }",
            "Sources/Mail/ThreadView.swift": "struct ThreadView { let title = \"Inbox\" }",
            "Sources/Mail/Signature.swift": "struct Signature { let text = \"--\" }"
        ])
        #expect(selection.files.contains("Sources/Mail/AttachmentRules.swift"))
        #expect(selection.files.contains("Sources/Mail/OutboxUploader.swift"))
        #expect(selection.reasons["Sources/Mail/OutboxUploader.swift"]?.contains { $0.contains("5000000") } == true)
        #expect(!selection.files.contains("Sources/Mail/ThreadView.swift"))
        #expect(!selection.files.contains("Sources/Mail/Signature.swift"))
    }

    @Test func definitionUsedBySelectedFileIsAdded() {
        let selection = select("CartScreen の合計表示を税込みにして", [
            "Sources/Shop/CartScreen.swift": "struct CartScreen { let formatter = PriceFormatter(); func total() -> String { formatter.text(1) } }",
            "Sources/Shop/PriceFormatter.swift": "struct PriceFormatter { func text(_ v: Int) -> String { \"\\(v)\" } }",
            "Sources/Shop/Wishlist.swift": "struct Wishlist { let items: [Int] = [] }"
        ])
        #expect(selection.files.contains("Sources/Shop/PriceFormatter.swift"))
        #expect(selection.reasons["Sources/Shop/PriceFormatter.swift"]?.first?.contains("PriceFormatter") == true)
        #expect(!selection.files.contains("Sources/Shop/Wishlist.swift"))
    }

    @Test func merelyUsingSelectedTypeIsNotEnough() {
        let selection = select("NoteStore に件数を返すメソッドを追加して", [
            "Sources/Notes/NoteStore.swift": "struct NoteStore { var notes: [String] = [] }",
            "Sources/Notes/NoteScreen.swift": "struct NoteScreen { let store = NoteStore() }",
            "Sources/Notes/NoteExporter.swift": "struct NoteExporter { func export(_ s: NoteStore) {} }"
        ])
        #expect(selection.files == ["Sources/Notes/NoteStore.swift"])
    }

    @Test func expansionIsCappedAndConventionalValuesIgnored() {
        var files = ["Sources/App/QuotaPolicy.swift": "enum QuotaPolicy { static let limit = 777_777; static let timeout = 30_000 }"]
        for i in 0..<5 { files["Sources/App/Worker\(i).swift"] = "struct Worker\(i) { let quota = 777_777 }" }
        for i in 0..<4 { files["Sources/App/Timer\(i).swift"] = "struct Timer\(i) { let timeout = 30_000 }" }
        let selection = select("QuotaPolicy の上限を見直して", files)
        let added = selection.files.filter { $0 != "Sources/App/QuotaPolicy.swift" }
        #expect(added.count <= ContextRelationships.maximumAdditions)
        // 30_000 appears in 5 files: a convention, never an expansion reason.
        #expect(!added.contains { $0.contains("Timer") })
    }

    @Test func constraintValuesNormaliseSeparators() {
        #expect(ContextRelationships.constraintValues("limit 20,000,000 and 20_000_000 and 999 and v1.2345") == ["20000000"])
        #expect(ContextRelationships.constraintValues("(1...100_000_000).contains(x)") == ["100000000"])
    }
}
