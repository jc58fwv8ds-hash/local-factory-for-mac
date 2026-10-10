import Foundation
import HarnessCore
import Observation

@MainActor
@Observable
final class VoiceCapsuleLibraryStore {
    enum Phase: Equatable {
        case idle
        case inspecting
        case creating
        case deleting
    }

    private(set) var manifests: [VoiceCapsuleManifest] = []
    private(set) var phase: Phase = .idle
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let assetStore: any VoiceCapsulePersisting

    init(assetStore: any VoiceCapsulePersisting = SystemVoiceCapsuleAssetStore()) {
        self.assetStore = assetStore
    }

    func refresh() async {
        do {
            manifests = try await assetStore.loadManifests()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func inspectMP3(at url: URL) async throws -> VoiceSampleInspection {
        phase = .inspecting
        defer { phase = .idle }
        do {
            let result = try await assetStore.inspectMP3(at: url)
            lastErrorMessage = nil
            return result
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func createFromMP3(
        at url: URL,
        displayName: String,
        transcript: String,
        confirmsRights: Bool
    ) async throws -> VoiceCapsuleManifest {
        phase = .creating
        defer { phase = .idle }
        do {
            let manifest = try await assetStore.createFromMP3(
                at: url,
                displayName: displayName,
                transcript: transcript,
                confirmsRights: confirmsRights
            )
            manifests.removeAll { $0.id == manifest.id }
            manifests.insert(manifest, at: 0)
            lastErrorMessage = nil
            return manifest
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func delete(id: UUID) async throws {
        phase = .deleting
        defer { phase = .idle }
        do {
            try await assetStore.delete(id: id)
            manifests.removeAll { $0.id == id }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func addTranscript(id: UUID, transcript: String) async throws {
        do {
            let manifest = try await assetStore.addTranscript(
                id: id,
                transcript: transcript
            )
            manifests.removeAll { $0.id == id }
            manifests.insert(manifest, at: 0)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }
}
