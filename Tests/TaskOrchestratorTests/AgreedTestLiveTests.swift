import Foundation
import Testing
@testable import TaskOrchestrator

/// Backlog #39 on a real isolated build (no model): a corrected case becomes a test that passes on the copy, and a
/// case needing a private helper of the visible tests is not offered. Runs with the pipeline tests (HARNESS_PIPELINE_TESTS=1).
@Suite(.serialized, .enabled(if: pipelineTestsEnabled))
struct AgreedTestLiveTests {
    let candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().resolvingSymlinksInPath()

    @Test func aCorrectedCaseBecomesAPassingProtectedTest() async throws {
        let base = candidate.appendingPathComponent("work/agreed-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("package")
        let visible = "import Testing\n@testable import Meter\n\nprivate func big() -> Int { 12 }\n@Test func capsAtTen() { #expect(Meter.level(big()) == 10) }\n"
        let files = [
            "Package.swift": "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Meter\", targets: [\n    .target(name: \"Meter\"),\n    .testTarget(name: \"MeterTests\", dependencies: [\"Meter\"])\n])\n",
            "Sources/Meter/Meter.swift": "public enum Meter { public static func level(_ v: Int) -> Int { min(v, 10) } }\n",
            "Tests/MeterTests/MeterTests.swift": visible]
        for (path, content) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let seed = ExampleCheckStage.Example(situation: "値が11", quantity: "レベル", setup: "", expression: "Meter.level(11)", alternatives: [])
        let agreed = try await ExampleCheckStage.agreedTest([seed], candidate: candidate, root: root.resolvingSymlinksInPath(),
            target: "MeterTests", module: "Meter", visibleTests: ["Tests/MeterTests/MeterTests.swift": visible],
            evidence: base.appendingPathComponent("evidence"))
        #expect(agreed?["path"] == "Tests/MeterTests/LocalFactoryAgreedTests.swift")
        #expect(agreed?["content"]?.contains(#"#expect(String(describing: value) == "10")"#) == true)
        // A case that needs the visible tests' private helper would not compile in the project: not offered.
        let needsHelper = ExampleCheckStage.Example(situation: "s", quantity: "q", setup: "", expression: "Meter.level(big())", alternatives: [])
        let refused = try await ExampleCheckStage.agreedTest([needsHelper], candidate: candidate, root: root.resolvingSymlinksInPath(),
            target: "MeterTests", module: "Meter", visibleTests: ["Tests/MeterTests/MeterTests.swift": visible],
            evidence: base.appendingPathComponent("evidence2"))
        #expect(refused == nil)
    }
}
