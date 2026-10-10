import AppKit
import SwiftUI

/// The card under a PDF edit: the steps in words, the resulting pages as pictures, and apply (new file) / discard / undo.
struct PDFChangeCard: View {
    let change: PDFChange
    @Bindable var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                Text("PDF の編集").font(.harness(.subheadline, weight: .semibold))
                Text(change.files.map(\.lastPathComponent).joined(separator: "、")).font(.harness(.caption)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            switch change.status {
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("操作を考えています。ファイルはまだ変更していません。").font(.harness(.caption)).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.harness(.caption)).foregroundStyle(.secondary)
            case .discarded:
                Text("この編集案は使いません。").font(.harness(.caption)).foregroundStyle(.secondary)
            case .ready, .applied:
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(change.steps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)").font(.harness(.caption))
                    }
                    Text("できあがり: \(change.pageCount) ページ").font(.harness(.caption2)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    ForEach(Array(change.thumbnails.enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image).resizable().scaledToFit().frame(height: 110)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
                    }
                }
                HStack(spacing: 8) {
                    if change.status == .ready {
                        Button("適用する(新しいファイルに書き出す)") { store.applyPDFChange(change) }.buttonStyle(.borderedProminent)
                        Button("やめる") { store.discardPDFChange(change) }
                    } else if case .applied(let url) = change.status {
                        Button("開く") { NSWorkspace.shared.open(url) }
                        Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("取り消す") { store.revertPDFChange(change) }
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
