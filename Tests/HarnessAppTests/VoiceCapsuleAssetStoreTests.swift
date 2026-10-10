@preconcurrency import AVFAudio
import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

struct VoiceCapsuleAssetStoreTests {
    @Test func systemImporterReadsARealMP3BeforeDurationGate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceMP3ImporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mp3URL = root.appendingPathComponent("source.mp3")
        let fixture = try #require(Data(base64Encoded: Self.shortMP3Base64))
        try fixture.write(to: mp3URL)

        let importer = SystemVoiceSampleImporter()
        do {
            _ = try await importer.inspectMP3(at: mp3URL)
            Issue.record("3秒未満のMP3が品質ゲートを通過しました")
        } catch let error as VoiceSampleImportError {
            #expect(error == .durationOutOfRange)
        }
    }

    @Test func normalizerProduces24kMonoWAV() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceNormalizerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputURL = root.appendingPathComponent("input.wav")
        let outputURL = root.appendingPathComponent("output.wav")
        try makeTestWave(at: inputURL)

        let importer = SystemVoiceSampleImporter()
        let data = try await importer.normalizedWAVData(from: inputURL)
        try data.write(to: outputURL)
        let output = try AVAudioFile(forReading: outputURL)
        #expect(data.starts(with: Data("RIFF".utf8)))
        #expect(output.processingFormat.sampleRate == 24_000)
        #expect(output.processingFormat.channelCount == 1)
        #expect(output.length >= 95_000)
        #expect(output.length <= 97_000)
    }

    @Test func providedRealMP3CompletesTheWholeImportPath() async throws {
        guard let path = ProcessInfo.processInfo.environment["HARNESS_REAL_MP3_FIXTURE"] else {
            return
        }
        let importer = SystemVoiceSampleImporter()
        let imported = try await importer.importMP3(at: URL(fileURLWithPath: path))
        #expect(imported.inspection.durationMilliseconds >= 3_000)
        #expect(imported.inspection.durationMilliseconds <= 30_000)
        #expect(imported.normalizedWAVData.starts(with: Data("RIFF".utf8)))
        #expect(imported.normalizedWAVData.count > 10_000)
    }

    @Test func mp3BecomesPrivatePortableCapsuleAndCanBeDeleted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCapsuleAssetStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = Data("normalized-wave-fixture".utf8)
        let importer = VoiceSampleImporterFixture(audioData: audio)
        let store = SystemVoiceCapsuleAssetStore(rootURL: root, importer: importer)

        let manifest = try await store.createFromMP3(
            at: URL(fileURLWithPath: "/private/tmp/my-voice.mp3"),
            displayName: "自分の声",
            transcript: "これは声の見本です。",
            confirmsRights: true
        )

        #expect(manifest.kind == .ownedVoice)
        #expect(manifest.consent.status == .userAttestedPrivateUse)
        #expect(manifest.usageScope == .privateOnDevice)
        #expect(manifest.syntheticDisclosureEnabled)
        #expect(manifest.references.first?.source == .importedAudio)
        #expect(manifest.references.first?.transcriptContentHash != nil)

        let directory = root.appendingPathComponent(manifest.id.uuidString.lowercased())
        #expect(posixPermissions(at: root) == 0o700)
        #expect(posixPermissions(at: directory) == 0o700)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("reference.wav").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.txt").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("my-voice.mp3").path))
        #expect(try Data(contentsOf: directory.appendingPathComponent("reference.wav")) == audio)
        #expect(posixPermissions(at: directory.appendingPathComponent("reference.wav")) == 0o600)
        #expect(posixPermissions(at: directory.appendingPathComponent("transcript.txt")) == 0o600)
        #expect(posixPermissions(at: directory.appendingPathComponent("manifest.json")) == 0o600)

        let reloaded = try await store.loadManifests()
        #expect(reloaded == [manifest])
        let engineInput = try await store.loadEngineInput(id: manifest.id)
        #expect(engineInput.manifest == manifest)
        #expect(engineInput.referenceAudio == audio)
        #expect(engineInput.referenceTranscript == "これは声の見本です。")
        #expect(VisualContentHash.isValidSHA256(engineInput.capsuleRevisionHash))
        try await store.delete(id: manifest.id)
        #expect(try await store.loadManifests().isEmpty)
    }

    @Test func privateCapsuleRequiresAttestationAndCannotBecomeExportable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCapsuleRightsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SystemVoiceCapsuleAssetStore(
            rootURL: root,
            importer: VoiceSampleImporterFixture(audioData: Data("wave".utf8))
        )
        do {
            _ = try await store.createFromMP3(
                at: URL(fileURLWithPath: "/private/tmp/voice.mp3"),
                displayName: "声",
                transcript: "",
                confirmsRights: false
            )
            Issue.record("権利確認なしでVoice Capsuleが作成されました")
        } catch let error as VoiceCapsuleStorageError {
            #expect(error == .rightsConfirmationRequired)
        }

        let hash = String(repeating: "a", count: 64)
        let exportManifest = VoiceCapsuleManifest(
            displayName: "声",
            kind: .ownedVoice,
            references: [VoiceReferenceDescriptor(
                displayName: "reference.wav",
                source: .importedAudio,
                durationMilliseconds: 8_000,
                audioContentHash: hash
            )],
            styleProfile: VoiceStyleProfile(languageCode: "ja-JP"),
            consent: VoiceConsentEvidence(status: .userAttestedPrivateUse),
            usageScope: .exportAllowed
        )
        #expect(
            VoiceCapsulePolicy.validationError(for: exportManifest)
                == .exportNeedsVerifiedConsent
        )
    }

    @Test func missingTranscriptCanBeAddedOnceWithoutChangingReferenceAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCapsuleTranscriptTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = Data("unchanged-reference-wave".utf8)
        let store = SystemVoiceCapsuleAssetStore(
            rootURL: root,
            importer: VoiceSampleImporterFixture(audioData: audio)
        )
        let manifest = try await store.createFromMP3(
            at: URL(fileURLWithPath: "/private/tmp/voice.mp3"),
            displayName: "声",
            transcript: "",
            confirmsRights: true
        )

        do {
            _ = try await store.addTranscript(id: manifest.id, transcript: "  ")
            Issue.record("空の文字起こしが追加されました")
        } catch let error as VoiceCapsuleStorageError {
            #expect(error == .transcriptRequired)
        }
        let updated = try await store.addTranscript(
            id: manifest.id,
            transcript: "  これは正確な見本です。\n"
        )
        let engineInput = try await store.loadEngineInput(id: manifest.id)

        #expect(updated.id == manifest.id)
        #expect(updated.createdAt == manifest.createdAt)
        #expect(updated.references.first?.id == manifest.references.first?.id)
        #expect(updated.references.first?.audioContentHash == manifest.references.first?.audioContentHash)
        #expect(updated.references.first?.transcriptContentHash != nil)
        #expect(engineInput.referenceAudio == audio)
        #expect(engineInput.referenceTranscript == "これは正確な見本です。")
        #expect(posixPermissions(at: root
            .appendingPathComponent(manifest.id.uuidString.lowercased())
            .appendingPathComponent("transcript.txt")) == 0o600)
        #expect(posixPermissions(at: root
            .appendingPathComponent(manifest.id.uuidString.lowercased())
            .appendingPathComponent("manifest.json")) == 0o600)

        do {
            _ = try await store.addTranscript(id: manifest.id, transcript: "別の内容")
            Issue.record("既存の文字起こしが確認なしで上書きされました")
        } catch let error as VoiceCapsuleStorageError {
            #expect(error == .transcriptAlreadyExists)
        }
    }

    @Test func fixtureWorkspaceKeepsCapsulesBesideTheFixture() {
        let temporary = FileManager.default.temporaryDirectory
        let fixture = temporary
            .appendingPathComponent("HarnessVoiceFixture", isDirectory: true)
            .appendingPathComponent("workspace.json")
        let root = HarnessAppEnvironment.voiceCapsuleRootURL(
            environment: [HarnessAppEnvironment.fixtureWorkspaceKey: fixture.path],
            temporaryDirectory: temporary
        )
        #expect(
            root.standardizedFileURL.path
                == fixture.deletingLastPathComponent()
                    .appendingPathComponent("VoiceCapsules").standardizedFileURL.path
        )
    }

    private func makeTestWave(at url: URL) throws {
        let sampleRate = 44_100.0
        let frameCount = AVAudioFrameCount(sampleRate * 4)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        let channels = try #require(buffer.floatChannelData)
        for index in 0..<Int(frameCount) {
            let sample = Float(sin(2 * .pi * 220 * Double(index) / sampleRate) * 0.12)
            channels[0][index] = sample
            channels[1][index] = sample
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func posixPermissions(at url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    private static let shortMP3Base64 = """
    SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjU2LjM2LjEwMAAAAAAAAAAAAAAA//OEAAAAAAAAAAAAAAAAAAAAAAAASW5mbwAAAA8AAAAEAAABIADAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDV1dXV1dXV1dXV1dXV1dXV1dXV1dXV1dXV6urq6urq6urq6urq6urq6urq6urq6urq6v////////////////////////////////8AAAAATGF2YzU2LjQxAAAAAAAAAAAAAAAAJAAAAAAAAAAAASDs90hvAAAAAAAAAAAAAAAAAAAA//MUZAAAAAGkAAAAAAAAA0gAAAAATEFN//MUZAMAAAGkAAAAAAAAA0gAAAAARTMu//MUZAYAAAGkAAAAAAAAA0gAAAAAOTku//MUZAkAAAGkAAAAAAAAA0gAAAAANVVV
    """
}

private actor VoiceSampleImporterFixture: VoiceSampleImporting {
    let audioData: Data

    init(audioData: Data) {
        self.audioData = audioData
    }

    func inspectMP3(at url: URL) async throws -> VoiceSampleInspection {
        inspection(for: url)
    }

    func importMP3(at url: URL) async throws -> ImportedVoiceSample {
        ImportedVoiceSample(
            inspection: inspection(for: url),
            normalizedWAVData: audioData
        )
    }

    private func inspection(for url: URL) -> VoiceSampleInspection {
        VoiceSampleInspection(
            displayName: url.lastPathComponent,
            durationMilliseconds: 8_000,
            byteCount: audioData.count,
            sampleRate: 44_100,
            channelCount: 2
        )
    }
}
