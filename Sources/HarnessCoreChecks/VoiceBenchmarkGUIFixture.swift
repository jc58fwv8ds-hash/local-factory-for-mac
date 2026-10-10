import Foundation
import HarnessCore

enum VoiceBenchmarkGUIFixture {
    static func prepare() throws {
        let manager = FileManager.default
        let container = manager.temporaryDirectory.appendingPathComponent(
            "Harness-GUI-VoiceBenchmark-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspaceURL = container.appendingPathComponent("Workspace/workspace.json")
        try WorkspaceRepository(fileURL: workspaceURL).saveLibrary(.starter)
        try createCapsule(beside: workspaceURL, manager: manager)
        try createReadyEngine(beside: workspaceURL, manager: manager)

        let data = try JSONEncoder().encode(
            VoiceBenchmarkFixtureOutput(workspacePath: workspaceURL.path)
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw CheckFailure(description: "Voice benchmark GUI fixture was not UTF-8")
        }
        print(text)
    }

    private static func createCapsule(
        beside workspaceURL: URL,
        manager: FileManager
    ) throws {
        let audio = Data("RIFF-voice-benchmark-gui-fixture".utf8)
        let transcript = Data("これは速度確認用の声です。".utf8)
        let manifest = VoiceCapsuleManifest(
            displayName: "マイボイス",
            kind: .ownedVoice,
            references: [VoiceReferenceDescriptor(
                displayName: "reference.wav",
                source: .importedAudio,
                durationMilliseconds: 8_000,
                audioContentHash: VisualContentHash.sha256Hex(of: audio),
                transcriptContentHash: VisualContentHash.sha256Hex(of: transcript)
            )],
            styleProfile: VoiceStyleProfile(languageCode: "ja-JP"),
            consent: VoiceConsentEvidence(status: .userAttestedPrivateUse)
        )
        let root = workspaceURL.deletingLastPathComponent()
            .appendingPathComponent("VoiceCapsules", isDirectory: true)
        let directory = root.appendingPathComponent(
            manifest.id.uuidString.lowercased(),
            isDirectory: true
        )
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try audio.write(to: directory.appendingPathComponent("reference.wav"))
        try transcript.write(to: directory.appendingPathComponent("transcript.txt"))
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json")
        )
        try secure(directory: root, manager: manager)
        try secure(directory: directory, manager: manager)
        for name in ["reference.wav", "transcript.txt", "manifest.json"] {
            try secure(file: directory.appendingPathComponent(name), manager: manager)
        }
    }

    private static func createReadyEngine(
        beside workspaceURL: URL,
        manager: FileManager
    ) throws {
        let active = workspaceURL.deletingLastPathComponent()
            .appendingPathComponent("VoiceEngines", isDirectory: true)
            .appendingPathComponent(VoiceEngineCatalog.qwen3TTSMLX.id, isDirectory: true)
            .appendingPathComponent("active", isDirectory: true)
        let runtime = active.appendingPathComponent("runtime/bin", isDirectory: true)
        let model = active.appendingPathComponent(
            "models/Qwen3-TTS-12Hz-0.6B-Base-bf16",
            isDirectory: true
        )
        try manager.createDirectory(at: runtime, withIntermediateDirectories: true)
        try manager.createDirectory(at: model, withIntermediateDirectories: true)
        let python = runtime.appendingPathComponent("python3")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: python)
        try Data("{}".utf8).write(to: model.appendingPathComponent("config.json"))
        try Data("fixture".utf8).write(to: model.appendingPathComponent("model.safetensors"))
        let receipt = VoiceEngineInstallationReceipt(
            engineIdentifier: VoiceEngineCatalog.qwen3TTSMLX.id,
            runtimeVersion: VoiceEngineCatalog.qwen3TTSMLXRuntimeVersion,
            modelIdentifier: VoiceEngineCatalog.qwen3TTSMLX.modelIdentifier,
            modelRevision: VoiceEngineCatalog.qwen3TTSMLXModelRevision
        )
        try JSONEncoder().encode(receipt).write(
            to: active.appendingPathComponent("installation.json")
        )
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: python.path
        )
    }

    private static func secure(directory: URL, manager: FileManager) throws {
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func secure(file: URL, manager: FileManager) throws {
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private struct VoiceBenchmarkFixtureOutput: Encodable {
    let workspacePath: String
}
