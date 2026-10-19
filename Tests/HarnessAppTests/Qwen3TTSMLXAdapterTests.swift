import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

struct Qwen3TTSMLXAdapterTests {
    @Test func packagedInstallerUsesPinnedRuntimeAndModelInputs() throws {
        let configuration = Qwen3TTSMLXConfiguration.managed()
        let lock = try String(
            contentsOf: configuration.runtimeProjectURL
                .appendingPathComponent("uv.lock"),
            encoding: .utf8
        )
        let worker = try String(
            contentsOf: configuration.installationWorkerURL,
            encoding: .utf8
        )

        #expect(lock.contains("name = \"mlx-audio\""))
        #expect(lock.contains("version = \"0.5.1\""))
        #expect(lock.contains("55ff0949d8c5750b9d779872dbaa874cf30ca21a04d282f7a4c3acc66962e45c"))
        // The worker takes the model, revision and hashes from the app (2026-10-19): it refuses to run without them and
        // checks every listed file; the pinned values live in Qwen3TTSModelVariant.
        #expect(worker.contains("--revision") && worker.contains("--expected") && worker.contains("hash mismatch"))
        let variant = VoiceEngineCatalog.qwen3TTSMLXVariant
        #expect(variant.revision.count == 40)
        #expect(!variant.expectedFiles.isEmpty && variant.expectedFiles.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 })
        #expect(Qwen3TTSMLXConfiguration.defaultUVArchiveSHA256.count == 64)
    }

    @Test func readinessExplainsWhichLocalComponentIsMissing() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        let adapter = Qwen3TTSMLXAdapter(configuration: fixture.configuration)

        #expect(await adapter.readiness().phase == .notInstalled)
        try fixture.createRuntime()
        #expect(await adapter.readiness().phase == .modelMissing)
        try fixture.createModel()
        #expect(await adapter.readiness().phase == .ready)
    }

    @Test func synthesisUsesPrivateRequestFilesAndValidatesWaveOutput() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.createRuntime()
        try fixture.createModel()
        let runner = SuccessfulVoiceEngineRunner()
        let adapter = Qwen3TTSMLXAdapter(
            configuration: fixture.configuration,
            commandRunner: runner
        )

        let spokenText = "秘密の返答です。"
        let audio = try await adapter.synthesize(
            text: spokenText,
            input: makeInput(hasTranscript: true)
        )
        let snapshot = try #require(await runner.snapshot())

        #expect(audio.wavData.starts(with: Data("RIFF".utf8)))
        #expect(audio.sampleRate == 24_000)
        #expect(audio.durationMilliseconds == 100)
        #expect(!snapshot.arguments.contains { $0.contains(spokenText) })
        #expect(snapshot.text == spokenText)
        #expect(snapshot.referenceText == "これは見本です。")
        #expect(snapshot.environment["HF_HUB_OFFLINE"] == "1")
        #expect(!FileManager.default.fileExists(atPath: snapshot.requestDirectory))
    }

    @Test func missingTranscriptStopsBeforeLaunchingRuntime() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.createRuntime()
        try fixture.createModel()
        let runner = SuccessfulVoiceEngineRunner()
        let adapter = Qwen3TTSMLXAdapter(
            configuration: fixture.configuration,
            commandRunner: runner
        )

        do {
            _ = try await adapter.synthesize(
                text: "確認します。",
                input: makeInput(hasTranscript: false)
            )
            Issue.record("文字起こしなしで音声生成が開始されました")
        } catch let error as VoiceEngineAdapterError {
            #expect(error == .policy(.referenceTranscriptRequired))
        }
        #expect(await runner.snapshot() == nil)
    }

    private func makeInput(hasTranscript: Bool) -> VoiceCapsuleEngineInput {
        let hash = String(repeating: "b", count: 64)
        let manifest = VoiceCapsuleManifest(
            displayName: "自分の声",
            kind: .ownedVoice,
            references: [VoiceReferenceDescriptor(
                displayName: "reference.wav",
                source: .importedAudio,
                durationMilliseconds: 8_000,
                audioContentHash: hash,
                transcriptContentHash: hasTranscript ? hash : nil
            )],
            styleProfile: VoiceStyleProfile(languageCode: "ja-JP"),
            consent: VoiceConsentEvidence(status: .userAttestedPrivateUse)
        )
        return VoiceCapsuleEngineInput(
            manifest: manifest,
            referenceAudio: Data("wave-fixture".utf8),
            referenceTranscript: hasTranscript ? "これは見本です。" : nil,
            capsuleRevisionHash: hash
        )
    }
}

private struct EngineFixture {
    let root: URL
    let configuration: Qwen3TTSMLXConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Qwen3TTSAdapterTests-\(UUID().uuidString)")
        configuration = Qwen3TTSMLXConfiguration(
            rootURL: root,
            workerURL: root.appendingPathComponent("qwen3_tts_worker.py")
        )
    }

    func createRuntime() throws {
        try FileManager.default.createDirectory(
            at: configuration.pythonExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: configuration.pythonExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: configuration.pythonExecutableURL.path
        )
        try Data("# worker fixture\n".utf8).write(to: configuration.workerURL)
    }

    func createModel() throws {
        try FileManager.default.createDirectory(
            at: configuration.modelURL,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: configuration.modelURL.appendingPathComponent("config.json")
        )
        try Data("weights".utf8).write(
            to: configuration.modelURL.appendingPathComponent("model.safetensors")
        )
        let receipt = VoiceEngineInstallationReceipt(
            engineIdentifier: VoiceEngineCatalog.qwen3TTSMLX.id,
            runtimeVersion: VoiceEngineCatalog.qwen3TTSMLXRuntimeVersion,
            modelIdentifier: VoiceEngineCatalog.qwen3TTSMLX.modelIdentifier,
            modelRevision: VoiceEngineCatalog.qwen3TTSMLXModelRevision
        )
        try JSONEncoder().encode(receipt).write(to: configuration.receiptURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor SuccessfulVoiceEngineRunner: VoiceEngineCommandRunning {
    struct Snapshot: Equatable, Sendable {
        let arguments: [String]
        let environment: [String: String]
        let text: String
        let referenceText: String
        let requestDirectory: String
    }

    private var lastSnapshot: Snapshot?

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> Int32 {
        let requestURL = URL(fileURLWithPath: try requestPath(from: arguments))
        let payload = try JSONSerialization.jsonObject(
            with: Data(contentsOf: requestURL)
        ) as? [String: Any]
        let textPath = try requiredString("textPath", in: payload)
        let referenceTextPath = try requiredString("referenceTextPath", in: payload)
        let outputPath = try requiredString("outputPath", in: payload)
        lastSnapshot = Snapshot(
            arguments: arguments,
            environment: environment,
            text: try String(contentsOfFile: textPath, encoding: .utf8),
            referenceText: try String(contentsOfFile: referenceTextPath, encoding: .utf8),
            requestDirectory: requestURL.deletingLastPathComponent().path
        )
        try Self.testWaveData().write(to: URL(fileURLWithPath: outputPath))
        return 0
    }

    func snapshot() -> Snapshot? { lastSnapshot }

    private func requestPath(from arguments: [String]) throws -> String {
        guard arguments.count == 3, arguments[1] == "--request" else {
            throw VoiceEngineRunnerFixtureError.invalidRequest
        }
        return arguments[2]
    }

    private func requiredString(
        _ key: String,
        in payload: [String: Any]?
    ) throws -> String {
        guard let value = payload?[key] as? String else {
            throw VoiceEngineRunnerFixtureError.invalidRequest
        }
        return value
    }

    private static func testWaveData() -> Data {
        let sampleRate: UInt32 = 24_000
        let sampleCount: UInt32 = 2_400
        let dataSize = sampleCount * 2
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(36 + dataSize)
        data.appendASCII("WAVEfmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(dataSize)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }
}

private enum VoiceEngineRunnerFixtureError: Error {
    case invalidRequest
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}

/// The resident speaker refuses to start without an installed runtime and says so (2026-10-19).
@Test func residentSpeakerWithoutAnEngineSaysItIsNotInstalled() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-\(UUID().uuidString)")
    let speaker = Qwen3TTSResidentSpeaker(configuration: Qwen3TTSMLXConfiguration(
        rootURL: root, workerURL: root.appendingPathComponent("qwen3_tts_worker.py")))
    await #expect(throws: Qwen3TTSResidentSpeaker.Failure.notInstalled) { try await speaker.start() }
    #expect(await speaker.isRunning == false)
}
