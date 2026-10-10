@preconcurrency import AVFAudio
import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

@MainActor
struct VoiceLibraryStoreTests {
    @Test func addingSelectingAndRemovingASystemVoicePersistsOnlyItsIdentifier() throws {
        let suite = "VoiceLibraryStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = VoiceCatalogFixture()
        let store = VoiceLibraryStore(
            defaults: defaults,
            catalog: catalog,
            preview: VoicePreviewSession(renderer: VoiceRendererFixture())
        )

        #expect(store.profiles.count == 3)
        #expect(store.addSystemVoice(identifier: "voice.reed"))
        #expect(store.selectedProfileID == "system.voice.reed")
        #expect(defaults.stringArray(forKey: "voiceLibrary.addedSystemVoiceIDs") == ["voice.reed"])

        let reloaded = VoiceLibraryStore(
            defaults: defaults,
            catalog: catalog,
            preview: VoicePreviewSession(renderer: VoiceRendererFixture())
        )
        #expect(reloaded.profiles.count == 4)
        #expect(reloaded.selectedProfile.displayName == "Reed")
        #expect(reloaded.remove(reloaded.selectedProfile))
        #expect(reloaded.selectedProfileID == VoiceModelCatalog.defaultProfileID)
        #expect(catalog.installedVoices().count == 2)
    }

    @Test func previewReceivesTheSelectedProfileAndCanBeStopped() async {
        let renderer = VoiceRendererFixture()
        let preview = VoicePreviewSession(renderer: renderer)
        let profile = VoiceModelCatalog.included[1]

        preview.toggle(profile)
        await Task.yield()
        #expect(renderer.receivedProfileIDs == [profile.id])
        preview.stop()
        #expect(renderer.stopCount >= 1)
        #expect(preview.playingProfileID == nil)
    }

    @Test func includedPresetResolvesToAnInstalledJapaneseVoice() {
        let catalog = AppleSystemVoiceCatalog()
        #expect(catalog.resolveVoice(for: VoiceModelCatalog.included[0]) != nil)
    }
}

@MainActor
private struct VoiceCatalogFixture: SystemVoiceCatalogProviding {
    func installedVoices() -> [SystemVoiceOption] {
        [
            SystemVoiceOption(id: "voice.reed", name: "Reed", languageCode: "ja-JP", quality: .premium),
            SystemVoiceOption(id: "voice.sandy", name: "Sandy", languageCode: "ja-JP", quality: .enhanced)
        ]
    }

    func resolveVoice(for profile: VoiceModelProfile) -> AVSpeechSynthesisVoice? { nil }
}

@MainActor
private final class VoiceRendererFixture: VoiceSpeechRendering {
    private(set) var receivedProfileIDs: [String] = []
    private(set) var stopCount = 0

    func speak(_ text: String, profile: VoiceModelProfile) async throws {
        receivedProfileIDs.append(profile.id)
        try await Task.sleep(for: .seconds(1))
    }

    func stop() {
        stopCount += 1
    }
}
