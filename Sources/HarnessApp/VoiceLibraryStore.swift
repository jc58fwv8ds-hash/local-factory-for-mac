import Foundation
import HarnessCore
import Observation

@MainActor
@Observable
final class VoiceLibraryStore {
    private(set) var selectedProfileID: String
    private(set) var addedSystemVoiceIDs: [String]
    private(set) var installedVoices: [SystemVoiceOption]
    let preview: VoicePreviewSession

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let catalog: any SystemVoiceCatalogProviding

    init(
        defaults: UserDefaults = .standard,
        catalog: any SystemVoiceCatalogProviding = AppleSystemVoiceCatalog(),
        preview: VoicePreviewSession = VoicePreviewSession()
    ) {
        self.defaults = defaults
        self.catalog = catalog
        self.preview = preview
        let identifiers = VoiceModelLibraryPolicy.boundedAddedIdentifiers(
            defaults.stringArray(forKey: Self.addedVoicesKey) ?? []
        )
        let voices = catalog.installedVoices()
        let profiles = Self.makeProfiles(identifiers: identifiers, voices: voices)
        self.addedSystemVoiceIDs = identifiers
        self.installedVoices = voices
        self.selectedProfileID = VoiceModelLibraryPolicy.resolvedSelection(
            persistedID: defaults.string(forKey: Self.selectedVoiceKey),
            availableProfiles: profiles
        )
    }

    var profiles: [VoiceModelProfile] {
        Self.makeProfiles(identifiers: addedSystemVoiceIDs, voices: installedVoices)
    }

    var selectedProfile: VoiceModelProfile {
        profiles.first(where: { $0.id == selectedProfileID })
            ?? VoiceModelCatalog.included[0]
    }

    var availableToAdd: [SystemVoiceOption] {
        let added = Set(addedSystemVoiceIDs)
        return installedVoices.filter { !added.contains($0.id) }
    }

    func refresh() {
        installedVoices = catalog.installedVoices()
        selectedProfileID = VoiceModelLibraryPolicy.resolvedSelection(
            persistedID: selectedProfileID,
            availableProfiles: profiles
        )
        persist()
    }

    @discardableResult
    func addSystemVoice(identifier: String) -> Bool {
        guard installedVoices.contains(where: { $0.id == identifier }) else { return false }
        let next = VoiceModelLibraryPolicy.boundedAddedIdentifiers(
            addedSystemVoiceIDs + [identifier]
        )
        guard next.count > addedSystemVoiceIDs.count else { return false }
        addedSystemVoiceIDs = next
        selectedProfileID = "system.\(identifier)"
        persist()
        return true
    }

    func select(_ profile: VoiceModelProfile) {
        guard profiles.contains(where: { $0.id == profile.id }) else { return }
        selectedProfileID = profile.id
        persist()
    }

    @discardableResult
    func remove(_ profile: VoiceModelProfile) -> Bool {
        guard profile.isRemovable,
              let identifier = profile.engineVoiceIdentifier else { return false }
        addedSystemVoiceIDs.removeAll { $0 == identifier }
        selectedProfileID = VoiceModelLibraryPolicy.resolvedSelection(
            persistedID: selectedProfileID,
            availableProfiles: profiles
        )
        persist()
        return true
    }

    private func persist() {
        defaults.set(addedSystemVoiceIDs, forKey: Self.addedVoicesKey)
        defaults.set(selectedProfileID, forKey: Self.selectedVoiceKey)
    }

    private static func makeProfiles(
        identifiers: [String],
        voices: [SystemVoiceOption]
    ) -> [VoiceModelProfile] {
        let voiceByID = Dictionary(
            voices.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let added = identifiers.compactMap { identifier -> VoiceModelProfile? in
            guard let voice = voiceByID[identifier] else { return nil }
            return VoiceModelCatalog.systemProfile(
                identifier: voice.id,
                name: voice.name,
                languageCode: voice.languageCode
            )
        }
        return VoiceModelCatalog.included + added
    }

    private static let selectedVoiceKey = "voiceLibrary.selectedProfileID"
    private static let addedVoicesKey = "voiceLibrary.addedSystemVoiceIDs"
}
