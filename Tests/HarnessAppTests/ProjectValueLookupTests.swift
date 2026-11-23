import Foundation
import Testing
@testable import HarnessCore

struct ProjectValueLookupTests {
    @Test func namesWhereAValueOfTheWantedTypeIs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pvl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "final class TranscriptStore {\n    static let shared = TranscriptStore()\n}".write(to: root.appendingPathComponent("TranscriptStore.swift"), atomically: true, encoding: .utf8)
        let hint = ProjectValueLookup.hint(for: "cannot convert value of type '[TranslationPair]' to expected argument type 'TranscriptStore'", projectRoot: root)
        #expect(hint?.contains("static let shared = TranscriptStore()") == true)
    }
}
