import HarnessCore
import Testing

struct VoiceModelLibraryTests {
    @Test func includedVoicesAreDistinctValidAndImmediatelySelectable() {
        let profiles = VoiceModelCatalog.included

        #expect(profiles.count == 3)
        #expect(Set(profiles.map(\.id)).count == profiles.count)
        #expect(profiles.first?.id == VoiceModelCatalog.defaultProfileID)
        #expect(profiles.allSatisfy(VoiceModelLibraryPolicy.isValid))
        #expect(profiles.allSatisfy { !$0.isRemovable })
    }

    @Test func systemVoiceUsesAnExactEngineIdentifierWithoutCloneData() {
        let profile = VoiceModelCatalog.systemProfile(
            identifier: "com.apple.voice.example",
            name: "Example",
            languageCode: "ja-JP"
        )

        #expect(VoiceModelLibraryPolicy.isValid(profile))
        #expect(profile.isRemovable)
        #expect(profile.engineVoiceIdentifier == "com.apple.voice.example")
        #expect(profile.source == .systemVoice)
    }

    @Test func persistedIdentifiersAreDeduplicatedBoundedAndSelectionRecovers() {
        let oversized = String(repeating: "x", count: 300)
        let identifiers = VoiceModelLibraryPolicy.boundedAddedIdentifiers(
            ["voice.a", "voice.a", oversized] + (0..<40).map { "voice.\($0)" }
        )

        #expect(identifiers.count == VoiceModelLibraryPolicy.maximumAddedVoices)
        #expect(identifiers.first == "voice.a")
        #expect(Set(identifiers).count == identifiers.count)
        #expect(VoiceModelLibraryPolicy.resolvedSelection(
            persistedID: "missing",
            availableProfiles: VoiceModelCatalog.included
        ) == VoiceModelCatalog.defaultProfileID)
    }
}
