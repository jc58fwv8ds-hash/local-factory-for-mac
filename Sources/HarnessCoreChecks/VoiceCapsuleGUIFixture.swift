import Foundation
import HarnessCore

enum VoiceCapsuleGUIFixture {
    static func prepare() throws {
        let manager = FileManager.default
        let container = manager.temporaryDirectory.appendingPathComponent(
            "Harness-GUI-VoiceCapsule-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspaceURL = container.appendingPathComponent("Workspace/workspace.json")
        try WorkspaceRepository(fileURL: workspaceURL).saveLibrary(.starter)

        let audio = Data("RIFF-voice-capsule-gui-fixture".utf8)
        let manifest = VoiceCapsuleManifest(
            displayName: "文字起こし未追加の声",
            kind: .ownedVoice,
            references: [VoiceReferenceDescriptor(
                displayName: "reference.wav",
                source: .importedAudio,
                durationMilliseconds: 8_000,
                audioContentHash: VisualContentHash.sha256Hex(of: audio)
            )],
            styleProfile: VoiceStyleProfile(languageCode: "ja-JP"),
            consent: VoiceConsentEvidence(status: .userAttestedPrivateUse)
        )
        let capsuleRoot = workspaceURL.deletingLastPathComponent()
            .appendingPathComponent("VoiceCapsules", isDirectory: true)
        let capsuleDirectory = capsuleRoot.appendingPathComponent(
            manifest.id.uuidString.lowercased(),
            isDirectory: true
        )
        try manager.createDirectory(at: capsuleDirectory, withIntermediateDirectories: true)
        try audio.write(to: capsuleDirectory.appendingPathComponent("reference.wav"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: capsuleDirectory.appendingPathComponent("manifest.json")
        )
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: capsuleRoot.path
        )
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: capsuleDirectory.path
        )
        for fileName in ["reference.wav", "manifest.json"] {
            try manager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: capsuleDirectory.appendingPathComponent(fileName).path
            )
        }

        let data = try JSONEncoder().encode(
            VoiceCapsuleFixtureOutput(workspacePath: workspaceURL.path)
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw CheckFailure(description: "Voice Capsule GUI fixture was not UTF-8")
        }
        print(text)
    }
}

private struct VoiceCapsuleFixtureOutput: Encodable {
    let workspacePath: String
}
