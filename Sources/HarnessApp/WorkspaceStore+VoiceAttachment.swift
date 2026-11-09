import Foundation
import HarnessCore

/// A voice made in another program, attached as the lines of the next video (2026-11-09, the user: lines made elsewhere
/// would make tests of plays easy). The mouth moves to it instead of to a voice made here. A voice longer than one clip
/// becomes scenes, each lip-synced to its own part of it, cut at pauses (long_video.py --voice).
struct AttachedVoice: Equatable {
    let file: URL
    let name: String
    var seconds: Double?
}

extension WorkspaceStore {
    nonisolated static let voiceTypes: Set<String> = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf", "flac"]
    /// Longer than this, the voice is spread over scenes instead of one clip.
    static let singleVoiceClip = 12.0

    nonisolated static func isVoiceFile(_ url: URL) -> Bool { voiceTypes.contains(url.pathExtension.lowercased()) }

    static var voiceFolder: URL { imageFolder.appendingPathComponent("voices", isDirectory: true) }

    /// A copy is kept, so the user's own file is never moved or removed; the copy goes once the video is made.
    func attachVoice(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: Self.voiceFolder, withIntermediateDirectories: true)
            let copy = Self.voiceFolder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
            try FileManager.default.copyItem(at: url, to: copy)
            removeVoice()
            attachedVoice = AttachedVoice(file: copy, name: url.lastPathComponent)
            if workspaceMode == .chat { composerPurpose = .video }
            Task {
                let seconds = await Self.seconds(of: copy)
                if attachedVoice?.file == copy { attachedVoice?.seconds = seconds }
            }
        } catch {
            presentNotice("音声ファイルを読み込めませんでした: \(error.localizedDescription)", kind: .information)
        }
    }

    func removeVoice() {
        if let file = attachedVoice?.file { try? FileManager.default.removeItem(at: file) }
        attachedVoice = nil
    }

    /// Scenes for a video: an attached voice longer than one clip sets them by its length; otherwise the length asked in
    /// words or chosen beside the input.
    func longSceneCount(_ change: ImageChange, option: PurposeModelOption, seconds: Int?) async -> Int? {
        guard change.isVideo, option.longCommand != nil else { return nil }
        if let file = change.voiceFile {
            guard let voiced = await Self.seconds(of: file), voiced > Self.singleVoiceClip else { return nil }
            return LongVideoPlan.sceneCount(seconds: Int(voiced.rounded(.up)))
        }
        return (LongVideoPlan.requestedSeconds(in: change.instruction) ?? seconds).flatMap(LongVideoPlan.sceneCount)
    }
}
