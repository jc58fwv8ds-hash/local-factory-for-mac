import Foundation
import HarnessCore

extension WorkspaceStore {
    func openVoiceLibrary() {
        voiceConversation.stop()
        voiceCapture.cancel()
        voiceLibrary.preview.stop()
        selectedSection = .voices
        Task { await voiceCapsules.refresh() }
    }

    func selectVoiceModel(_ profile: VoiceModelProfile) {
        voiceLibrary.preview.stop()
        voiceLibrary.select(profile)
        presentNotice("\(profile.displayName)を会話の声にしました", kind: .success)
    }

    func addSystemVoice(_ option: SystemVoiceOption) -> Bool {
        let added = voiceLibrary.addSystemVoice(identifier: option.id)
        if added {
            presentNotice("\(option.name)を音声ライブラリへ追加しました", kind: .success)
        } else {
            presentNotice("この音声は追加済みか、追加上限に達しています", kind: .information)
        }
        return added
    }

    func removeVoiceModel(_ profile: VoiceModelProfile) {
        voiceLibrary.preview.stop()
        guard voiceLibrary.remove(profile) else { return }
        presentNotice("\(profile.displayName)を一覧から外しました。Macの音声自体は削除していません。", kind: .information)
    }

    func createVoiceCapsule(
        from url: URL,
        displayName: String,
        transcript: String,
        confirmsRights: Bool
    ) async -> Bool {
        do {
            let manifest = try await voiceCapsules.createFromMP3(
                at: url,
                displayName: displayName,
                transcript: transcript,
                confirmsRights: confirmsRights
            )
            presentNotice("\(manifest.displayName)を端末内の声モデルとして保存しました", kind: .success)
            return true
        } catch {
            presentNotice("声モデルを作れませんでした：\(error.localizedDescription)", kind: .error)
            return false
        }
    }

    func removeVoiceCapsule(_ manifest: VoiceCapsuleManifest) async {
        do {
            try await voiceCapsules.delete(id: manifest.id)
            presentNotice("\(manifest.displayName)と保存した見本音声を削除しました", kind: .information)
        } catch {
            presentNotice("声モデルを削除できませんでした：\(error.localizedDescription)", kind: .error)
        }
    }

    func addTranscript(
        _ transcript: String,
        to manifest: VoiceCapsuleManifest
    ) async -> Bool {
        do {
            try await voiceCapsules.addTranscript(id: manifest.id, transcript: transcript)
            presentNotice("\(manifest.displayName)に文字起こしを追加しました", kind: .success)
            return true
        } catch {
            presentNotice("文字起こしを追加できませんでした：\(error.localizedDescription)", kind: .error)
            return false
        }
    }
}
