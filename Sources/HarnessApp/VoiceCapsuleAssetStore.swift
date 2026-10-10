import Foundation
import HarnessCore

enum VoiceCapsuleStorageError: LocalizedError, Equatable {
    case rightsConfirmationRequired
    case transcriptRequired
    case transcriptTooLong
    case transcriptAlreadyExists
    case invalidManifest(VoiceCapsulePolicyError)
    case unreadableLibrary
    case capsuleNotFound

    var errorDescription: String? {
        switch self {
        case .rightsConfirmationRequired:
            "本人の声、または利用許可を得た声であることを確認してください。"
        case .transcriptRequired:
            VoiceCapsuleTranscriptPolicyError.empty.localizedDescription
        case .transcriptTooLong:
            VoiceCapsuleTranscriptPolicyError.tooLong.localizedDescription
        case .transcriptAlreadyExists:
            "この声モデルには文字起こしが追加済みです。"
        case .invalidManifest(let error):
            error.localizedDescription
        case .unreadableLibrary:
            "保存した声モデルを安全に読み込めませんでした。"
        case .capsuleNotFound:
            "この声モデルはすでに削除されています。"
        }
    }
}

protocol VoiceCapsulePersisting: Sendable {
    func inspectMP3(at url: URL) async throws -> VoiceSampleInspection
    func loadManifests() async throws -> [VoiceCapsuleManifest]
    func loadEngineInput(id: UUID) async throws -> VoiceCapsuleEngineInput
    func addTranscript(id: UUID, transcript: String) async throws -> VoiceCapsuleManifest
    func createFromMP3(
        at url: URL,
        displayName: String,
        transcript: String,
        confirmsRights: Bool
    ) async throws -> VoiceCapsuleManifest
    func delete(id: UUID) async throws
}

actor SystemVoiceCapsuleAssetStore: VoiceCapsulePersisting {
    private let rootURL: URL
    private let importer: any VoiceSampleImporting
    private let fileManager: FileManager

    init(
        rootURL: URL = HarnessAppEnvironment.voiceCapsuleRootURL(),
        importer: any VoiceSampleImporting = SystemVoiceSampleImporter(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.importer = importer
        self.fileManager = fileManager
    }

    func inspectMP3(at url: URL) async throws -> VoiceSampleInspection {
        try await importer.inspectMP3(at: url)
    }

    func loadManifests() async throws -> [VoiceCapsuleManifest] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        do {
            try applyPrivateDirectoryPermissions(to: rootURL)
        } catch {
            throw VoiceCapsuleStorageError.unreadableLibrary
        }
        let directories: [URL]
        do {
            directories = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw VoiceCapsuleStorageError.unreadableLibrary
        }
        return directories.compactMap(loadValidManifest).sorted { left, right in
            left.createdAt > right.createdAt
        }
    }

    func loadEngineInput(id: UUID) async throws -> VoiceCapsuleEngineInput {
        let directory = capsuleDirectory(for: id)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw VoiceCapsuleStorageError.capsuleNotFound
        }
        guard let manifest = loadValidManifest(from: directory),
              let audio = try? Data(
                contentsOf: directory.appendingPathComponent(Self.audioFileName)
              ) else {
            throw VoiceCapsuleStorageError.unreadableLibrary
        }
        let transcript: String?
        if manifest.references.first?.transcriptContentHash != nil {
            guard let data = try? Data(
                contentsOf: directory.appendingPathComponent(Self.transcriptFileName)
            ), let decoded = String(data: data, encoding: .utf8) else {
                throw VoiceCapsuleStorageError.unreadableLibrary
            }
            transcript = decoded
        } else {
            transcript = nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let manifestData = try? encoder.encode(manifest) else {
            throw VoiceCapsuleStorageError.unreadableLibrary
        }
        return VoiceCapsuleEngineInput(
            manifest: manifest,
            referenceAudio: audio,
            referenceTranscript: transcript,
            capsuleRevisionHash: VisualContentHash.sha256Hex(of: manifestData)
        )
    }

    func createFromMP3(
        at url: URL,
        displayName: String,
        transcript: String,
        confirmsRights: Bool
    ) async throws -> VoiceCapsuleManifest {
        guard confirmsRights else {
            throw VoiceCapsuleStorageError.rightsConfirmationRequired
        }
        let cleanedTranscript = VoiceCapsuleTranscriptPolicy.normalized(transcript)
        guard VoiceCapsuleTranscriptPolicy.validationError(
            for: cleanedTranscript,
            allowsEmpty: true
        ) == nil else {
            throw VoiceCapsuleStorageError.transcriptTooLong
        }
        let sample = try await importer.importMP3(at: url)
        let audioHash = VisualContentHash.sha256Hex(of: sample.normalizedWAVData)
        let transcriptData = cleanedTranscript.isEmpty ? nil : Data(cleanedTranscript.utf8)
        let reference = VoiceReferenceDescriptor(
            displayName: "reference.wav",
            source: .importedAudio,
            durationMilliseconds: sample.inspection.durationMilliseconds,
            audioContentHash: audioHash,
            transcriptContentHash: transcriptData.map(VisualContentHash.sha256Hex)
        )
        let manifest = VoiceCapsuleManifest(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: .ownedVoice,
            references: [reference],
            styleProfile: VoiceStyleProfile(languageCode: "ja-JP"),
            consent: VoiceConsentEvidence(status: .userAttestedPrivateUse),
            usageScope: .privateOnDevice,
            syntheticDisclosureEnabled: true
        )
        if let error = VoiceCapsulePolicy.validationError(for: manifest) {
            throw VoiceCapsuleStorageError.invalidManifest(error)
        }
        try persist(
            manifest: manifest,
            audioData: sample.normalizedWAVData,
            transcriptData: transcriptData
        )
        return manifest
    }

    func addTranscript(id: UUID, transcript: String) async throws -> VoiceCapsuleManifest {
        let cleanedTranscript = VoiceCapsuleTranscriptPolicy.normalized(transcript)
        if let error = VoiceCapsuleTranscriptPolicy.validationError(
            for: cleanedTranscript,
            allowsEmpty: false
        ) {
            throw error == .empty
                ? VoiceCapsuleStorageError.transcriptRequired
                : VoiceCapsuleStorageError.transcriptTooLong
        }
        let directory = capsuleDirectory(for: id)
        guard let manifest = loadValidManifest(from: directory),
              let reference = manifest.references.first else {
            throw VoiceCapsuleStorageError.capsuleNotFound
        }
        guard reference.transcriptContentHash == nil else {
            throw VoiceCapsuleStorageError.transcriptAlreadyExists
        }
        let transcriptData = Data(cleanedTranscript.utf8)
        let updatedReference = VoiceReferenceDescriptor(
            id: reference.id,
            displayName: reference.displayName,
            source: reference.source,
            durationMilliseconds: reference.durationMilliseconds,
            audioContentHash: reference.audioContentHash,
            transcriptContentHash: VisualContentHash.sha256Hex(of: transcriptData),
            alignmentContentHash: reference.alignmentContentHash
        )
        let updatedManifest = VoiceCapsuleManifest(
            id: manifest.id,
            schemaVersion: manifest.schemaVersion,
            createdAt: manifest.createdAt,
            displayName: manifest.displayName,
            kind: manifest.kind,
            references: [updatedReference] + manifest.references.dropFirst(),
            styleProfile: manifest.styleProfile,
            consent: manifest.consent,
            usageScope: manifest.usageScope,
            syntheticDisclosureEnabled: manifest.syntheticDisclosureEnabled
        )
        if let error = VoiceCapsulePolicy.validationError(for: updatedManifest) {
            throw VoiceCapsuleStorageError.invalidManifest(error)
        }
        let transcriptURL = directory.appendingPathComponent(Self.transcriptFileName)
        try transcriptData.write(to: transcriptURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: transcriptURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestURL = directory.appendingPathComponent(Self.manifestFileName)
        try encoder.encode(updatedManifest).write(to: manifestURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestURL.path
        )
        return updatedManifest
    }

    func delete(id: UUID) async throws {
        let directory = capsuleDirectory(for: id)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw VoiceCapsuleStorageError.capsuleNotFound
        }
        try fileManager.removeItem(at: directory)
    }

    private func persist(
        manifest: VoiceCapsuleManifest,
        audioData: Data,
        transcriptData: Data?
    ) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try applyPrivateDirectoryPermissions(to: rootURL)
        let staging = rootURL.appendingPathComponent(
            ".staging-\(manifest.id.uuidString.lowercased())",
            isDirectory: true
        )
        let destination = capsuleDirectory(for: manifest.id)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try audioData.write(
                to: staging.appendingPathComponent(Self.audioFileName),
                options: .atomic
            )
            if let transcriptData {
                try transcriptData.write(
                    to: staging.appendingPathComponent(Self.transcriptFileName),
                    options: .atomic
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: staging.appendingPathComponent(Self.manifestFileName),
                options: .atomic
            )
            try fileManager.moveItem(at: staging, to: destination)
            try applyPrivatePermissions(to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func loadValidManifest(from directory: URL) -> VoiceCapsuleManifest? {
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let data = try? Data(contentsOf: directory.appendingPathComponent(Self.manifestFileName)),
              let manifest = try? JSONDecoder().decode(VoiceCapsuleManifest.self, from: data),
              capsuleDirectory(for: manifest.id).standardizedFileURL == directory.standardizedFileURL,
              VoiceCapsulePolicy.validationError(for: manifest) == nil,
              let reference = manifest.references.first,
              let audio = try? Data(contentsOf: directory.appendingPathComponent(Self.audioFileName)),
              VisualContentHash.sha256Hex(of: audio) == reference.audioContentHash else {
            return nil
        }
        if let transcriptHash = reference.transcriptContentHash {
            guard let transcript = try? Data(
                contentsOf: directory.appendingPathComponent(Self.transcriptFileName)
            ), VisualContentHash.sha256Hex(of: transcript) == transcriptHash else {
                return nil
            }
        }
        return manifest
    }

    private func capsuleDirectory(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func applyPrivatePermissions(to directory: URL) throws {
        try applyPrivateDirectoryPermissions(to: directory)
        for name in [Self.audioFileName, Self.transcriptFileName, Self.manifestFileName] {
            let url = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    private func applyPrivateDirectoryPermissions(to directory: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private static let audioFileName = "reference.wav"
    private static let transcriptFileName = "transcript.txt"
    private static let manifestFileName = "manifest.json"
}
