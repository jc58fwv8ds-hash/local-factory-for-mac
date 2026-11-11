import Foundation
import HarnessCore
import Testing

struct AppleAppFrameworkEmbedderTests {
    private func project() throws -> (URL, URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let result = try AppleAppScaffolder().create(.init(parentDirectoryPath: parent.path, productName: "EmbedProbe",
                                                           displayName: "Embed Probe"))
        let framework = parent.appendingPathComponent("tiny.xcframework")
        try FileManager.default.createDirectory(at: framework.appendingPathComponent("ios-arm64"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: framework.appendingPathComponent("Info.plist"))
        return (URL(fileURLWithPath: result.rootPath), framework)
    }

    @Test func linksAndEmbedsInTheAppTargetOnly() throws {
        let (root, framework) = try project()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(try AppleAppFrameworkEmbedder.add(framework, to: root) == "Frameworks/tiny.xcframework")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Frameworks/tiny.xcframework/Info.plist").path))
        let text = try String(contentsOf: root.appendingPathComponent("EmbedProbe.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(text.contains("path = Frameworks/tiny.xcframework;"))
        #expect(text.contains("dstSubfolderSpec = 10;"))
        #expect(text.contains("CodeSignOnCopy"))
        let app = text.components(separatedBy: "\n").first { $0.contains("com.apple.product-type.application") }!
        let tests = text.components(separatedBy: "\n").first { $0.contains("com.apple.product-type.bundle.unit-test") }!
        #expect(app.components(separatedBy: ",").count == 4)       // sources, frameworks, resources, embed
        #expect(!tests.contains("K0000"))
        let plutil = Process()
        plutil.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        plutil.arguments = ["-lint", root.appendingPathComponent("EmbedProbe.xcodeproj/project.pbxproj").path]
        plutil.standardOutput = FileHandle.nullDevice
        try plutil.run(); plutil.waitUntilExit()
        #expect(plutil.terminationStatus == 0)
    }

    @Test func refusesTheSameFrameworkTwice() throws {
        let (root, framework) = try project()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try AppleAppFrameworkEmbedder.add(framework, to: root)
        #expect(throws: AppleAppFrameworkEmbedder.Failure.alreadyAdded) { try AppleAppFrameworkEmbedder.add(framework, to: root) }
    }
}
