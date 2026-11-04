import AppKit
import AVKit
import SwiftUI

/// The card under an image request: progress, the finished picture (saved on this Mac), or why it failed.
struct ImageChangeCard: View {
    let change: ImageChange
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: change.isVideo ? "film" : "photo.artframe")
                Text(change.isVideo ? "動画" : "画像").font(.harness(.subheadline, weight: .semibold))
                Spacer()
                if change.isRunning { Button("止める", systemImage: "stop.fill", action: stop).controlSize(.small) }
            }
            switch change.status {
            case .running(let step):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.harness(.caption)).foregroundStyle(.secondary)
                }
                if let kind = change.jobKind { RemainingTimeLabel(kind: kind, startedAt: change.startedAt) }
            case .stopped:
                Text("止めました。").font(.harness(.caption)).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.harness(.caption)).foregroundStyle(.secondary)
            case .ready(let url):
                if change.isVideo {
                    VideoPreview(url: url).frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 8) {
                    Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("開く") { NSWorkspace.shared.open(url) }
                }
                .controlSize(.small)
            }
            if let prompt = change.prompt, prompt != change.instruction {
                Text((change.isVideo ? "動画モデルへの指示: " : "画像モデルへの指示: ") + prompt).font(.harness(.caption2)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}

/// The player, from AppKit (2026-11-05): SwiftUI's VideoPlayer aborted the whole app the moment a finished video was shown
/// (getSuperclassMetadata inside _AVKit_SwiftUI on macOS 27.2).
struct VideoPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause() }
}
