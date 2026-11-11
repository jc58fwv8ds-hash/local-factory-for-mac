import Foundation
import Testing
@testable import HarnessCore

struct MissingResourceCheckTests {
    @Test func namesModelFilesInLiteralsAndResourcePairs() {
        #expect(MissingResourceCheck.namedFiles(in: #"let fileName = "plamo-7b-q4_k_m.gguf""#) == ["plamo-7b-q4_k_m.gguf"])
        #expect(MissingResourceCheck.namedFiles(in: #"Bundle.main.url(forResource: "model", withExtension: "gguf")"#) == ["model.gguf"])
        #expect(MissingResourceCheck.namedFiles(in: #"let icon = "AppIcon.png""#).isEmpty)
    }

    @Test func reportsAMissingModelWithTheOneThatExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("missing-resource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App/Models"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("App/Models/plamo-3-translate-0.8b-Q4_K_M.gguf"))
        try #"let a = "plamo-7b-q4_k_m.gguf"\nlet b = "plamo-3-translate-0.8b-Q4_K_M.gguf""#
            .replacingOccurrences(of: "\\n", with: "\n").write(to: root.appendingPathComponent("App/Controller.swift"), atomically: true, encoding: .utf8)
        let found = MissingResourceCheck.diagnostics(rootURL: root)
        #expect(found.count == 1)
        #expect(found.first?.relativePath == "App/Controller.swift")
        #expect(found.first?.line == 1)
        #expect(found.first?.message.contains("「plamo-3-translate-0.8b-Q4_K_M.gguf」") == true)
    }
}
