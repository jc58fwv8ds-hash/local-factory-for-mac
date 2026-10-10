import AppKit
import SwiftUI

/// The card under a Word edit: each changed paragraph before → after, and apply (new file) / discard / undo.
struct WordChangeCard: View {
    let change: WordChange
    @Bindable var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                Text("文書の直し").font(.harness(.subheadline, weight: .semibold))
                Text(change.source.lastPathComponent).font(.harness(.caption)).foregroundStyle(.secondary)
                Spacer()
            }
            switch change.status {
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("直す部分を考えています。ファイルはまだ変更していません。").font(.harness(.caption)).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.harness(.caption)).foregroundStyle(.secondary)
            case .discarded:
                Text("この直し案は使いません。").font(.harness(.caption)).foregroundStyle(.secondary)
            case .ready, .applied:
                ForEach(Array(change.changes.enumerated()), id: \.offset) { _, paragraph in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(paragraph.before).strikethrough().foregroundStyle(.secondary)
                        Text(paragraph.after)
                    }
                    .font(.harness(.caption))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack(spacing: 8) {
                    if change.status == .ready {
                        Button("適用する(新しいファイルに書き出す)") { store.applyWordChange(change) }.buttonStyle(.borderedProminent)
                        Button("やめる") { store.discardWordChange(change) }
                    } else if case .applied(let url) = change.status {
                        Button("開く") { NSWorkspace.shared.open(url) }
                        Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("取り消す") { store.revertWordChange(change) }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}
