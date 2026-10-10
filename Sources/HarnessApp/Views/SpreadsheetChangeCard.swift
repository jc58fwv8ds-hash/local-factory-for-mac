import AppKit
import SwiftUI

/// The card under a spreadsheet edit: the before → after cells, and apply (new file) / discard / undo.
struct SpreadsheetChangeCard: View {
    let change: SpreadsheetChange
    @Bindable var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells")
                Text("セルの書き換え").font(.harness(.subheadline, weight: .semibold))
                Text(change.source.lastPathComponent).font(.harness(.caption)).foregroundStyle(.secondary)
                Spacer()
                Text(statusText).font(.harness(.caption, weight: .medium)).foregroundStyle(.secondary)
            }
            switch change.status {
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("書き換えるセルを考えています。ファイルはまだ変更していません。").font(.harness(.caption)).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.harness(.caption)).foregroundStyle(.secondary)
            case .discarded:
                Text("この書き換え案は使いません。").font(.harness(.caption)).foregroundStyle(.secondary)
            case .ready, .applied:
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(change.changes.prefix(40).enumerated()), id: \.offset) { _, cell in
                        HStack(spacing: 6) {
                            Text("\(cell.sheet) \(cell.cell)").frame(width: 120, alignment: .leading)
                            Text(cell.before.isEmpty ? "(空)" : cell.before).foregroundStyle(.secondary).lineLimit(1)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(cell.after).lineLimit(1)
                        }
                        .font(.harness(.caption).monospaced())
                    }
                    if change.changes.count > 40 {
                        Text("ほか \(change.changes.count - 40) か所").font(.harness(.caption2)).foregroundStyle(.secondary)
                    }
                    if change.edits.contains(where: { $0.formula != nil }) {
                        Text("数式の結果は、Excel で開いたときに計算されます。").font(.harness(.caption2)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if change.status == .ready {
                        Button("適用する(新しいファイルに書き出す)") { store.applySpreadsheetChange(change) }
                            .buttonStyle(.borderedProminent)
                        Button("やめる") { store.discardSpreadsheetChange(change) }
                    } else if case .applied(let url) = change.status {
                        Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("取り消す") { store.revertSpreadsheetChange(change) }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    private var statusText: String {
        switch change.status {
        case .running: "作業中"
        case .ready: "下見・未適用"
        case .applied: "書き出し済み"
        case .failed: "作れませんでした"
        case .discarded: "取りやめ"
        }
    }
}
