import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

struct Qwen3TTSMLXInstallerTests {
    @Test func completeBootstrapArchiveResumesAtVerificationWithoutAnotherDownload() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.remove() }
        try fixture.writeArchive(fixture.completeArchive)
        let runner = BootstrapRunner(fixture: fixture, failFirstResume: false)
        let installer = Qwen3TTSMLXInstaller(
            configuration: fixture.configuration,
            commandRunner: runner
        )

        try await installer.prepareBootstrap { _ in }
        let calls = await runner.recordedCalls()

        #expect(calls.map(\.executable) == ["tar"])
        #expect(FileManager.default.isExecutableFile(
            atPath: fixture.configuration.uvExecutableURL.path
        ))
    }

    @Test func failedRangeResumeRetriesOnceFromTheSamePinnedURL() async throws {
        let fixture = try BootstrapFixture()
        defer { fixture.remove() }
        try fixture.writeArchive(Data("partial".utf8))
        let runner = BootstrapRunner(fixture: fixture, failFirstResume: true)
        let installer = Qwen3TTSMLXInstaller(
            configuration: fixture.configuration,
            commandRunner: runner
        )

        try await installer.prepareBootstrap { _ in }
        let calls = await runner.recordedCalls()

        #expect(calls.map(\.executable) == ["curl", "curl", "tar"])
        #expect(calls[0].arguments.contains("--continue-at"))
        #expect(!calls[1].arguments.contains("--continue-at"))
        #expect(calls[0].arguments.last == fixture.configuration.uvArchiveRemoteURL.absoluteString)
        #expect(calls[1].arguments.last == fixture.configuration.uvArchiveRemoteURL.absoluteString)
    }
}

private struct BootstrapFixture: Sendable {
    let root: URL
    let completeArchive = Data("verified bootstrap archive".utf8)
    let configuration: Qwen3TTSMLXConfiguration

    init() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VoiceEngineBootstrapTests-\(UUID().uuidString)",
            isDirectory: true
        )
        root = container.appendingPathComponent(
            VoiceEngineCatalog.qwen3TTSMLX.id,
            isDirectory: true
        )
        let archive = Data("verified bootstrap archive".utf8)
        configuration = Qwen3TTSMLXConfiguration(
            rootURL: root,
            workerURL: container.appendingPathComponent("worker.py"),
            uvArchiveRemoteURL: URL(string: "https://example.invalid/pinned-uv.tar.gz")!,
            uvArchiveSHA256: VisualContentHash.sha256Hex(of: archive)
        )
    }

    func writeArchive(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: configuration.bootstrapArchiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: configuration.bootstrapArchiveURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

private actor BootstrapRunner: VoiceEngineInstallationCommandRunning {
    struct Call: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    private let fixture: BootstrapFixture
    private let failFirstResume: Bool
    private var didFailResume = false
    private var calls: [Call] = []

    init(fixture: BootstrapFixture, failFirstResume: Bool) {
        self.fixture = fixture
        self.failFirstResume = failFirstResume
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        onOutput: (@Sendable (String) async -> Void)?
    ) async throws -> Int32 {
        calls.append(Call(executable: executableURL.lastPathComponent, arguments: arguments))
        if executableURL.lastPathComponent == "curl" {
            if failFirstResume, !didFailResume, arguments.contains("--continue-at") {
                didFailResume = true
                return 33
            }
            try fixture.completeArchive.write(to: fixture.configuration.bootstrapArchiveURL)
            return 0
        }
        if executableURL.lastPathComponent == "tar" {
            try FileManager.default.createDirectory(
                at: fixture.configuration.uvExecutableURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\n".utf8).write(to: fixture.configuration.uvExecutableURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.configuration.uvExecutableURL.path
            )
            return 0
        }
        return 1
    }

    func recordedCalls() -> [Call] { calls }
}
