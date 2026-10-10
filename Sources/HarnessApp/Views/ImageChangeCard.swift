import AppKit
import SwiftUI

/// The card under an image request: progress, the finished picture (saved on this Mac), or why it failed.
struct ImageChangeCard: View {
    let change: ImageChange

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "photo.artframe")
                Text("画像").font(.harness(.subheadline, weight: .semibold))
                Spacer()
            }
            switch change.status {
            case .running(let step):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.harness(.caption)).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.harness(.caption)).foregroundStyle(.secondary)
            case .ready(let url):
                if let image = NSImage(contentsOf: url) {
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
                Text("画像モデルへの指示: " + prompt).font(.harness(.caption2)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}
