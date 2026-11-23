import Foundation
import Testing
@testable import HarnessCore

struct SendableClosureRetargetTests {
    @Test func sendsTheRepairToTheDeclaration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "actor Translator {\n    func translate(_ text: String, onSegmentComplete: @escaping (String) -> Void) {\n    }\n}"
            .write(to: root.appendingPathComponent("App/Translator.swift"), atomically: true, encoding: .utf8)
        try "final class Controller {\n    func go() async {\n        await translator.translate(\n            text,\n            onSegmentComplete: { s in print(s) })\n    }\n}"
            .write(to: root.appendingPathComponent("App/Controller.swift"), atomically: true, encoding: .utf8)
        let error = BuildFailureDiagnostic(validationKind: .build, relativePath: "App/Controller.swift", line: 3, column: 9,
                                           message: "sending value of non-Sendable type '(String) -> Void' risks causing data races")
        let result = SendableClosureRetarget.retarget([error], rootURL: root)
        #expect(result.count == 1)
        #expect(result[0].relativePath == "App/Translator.swift")
        #expect(result[0].line == 2)
        #expect(result[0].message.contains("@Sendable (String) -> Void"))
    }
}
