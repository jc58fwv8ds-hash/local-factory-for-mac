import HarnessCore
import SwiftUI

/// The card under a rename request: the rule in words, the before → after table, problems, and apply / discard / undo.
struct RenameChangeCard: View {
    let change: RenameChange
    @Bindable var store: WorkspaceStore
    private let shownRows = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "character.cursor.ibeam")
                Text("名前の一括変更").font(.harness(.subheadline, weight: .semibold))
                Text(change.folder.lastPathComponent).font(.harness(.caption)).foregroundStyle(.secondary)
                Spacer()
                statusLabel
            }
            switch change.status {
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("名前の付け方を考えています。ファイルはまだ変更していません。")
                        .font(.harness(.caption)).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.harness(.caption)).foregroundStyle(.secondary)
            case .discarded:
                Text("この変更案は使いません。").font(.harness(.caption)).foregroundStyle(.secondary)
            case .ready, .applied:
                if let plan = change.plan { table(plan) }
                actions
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    private var statusLabel: some View {
        let (text, color): (String, Color) = switch change.status {
        case .running: ("作業中", .secondary)
        case .ready: (change.plan?.canApply == true ? "下見・未適用" : "このままでは適用できません", change.plan?.canApply == true ? .green : .orange)
        case .applied: ("適用済み", .accentColor)
        case .failed: ("作れませんでした", .orange)
        case .discarded: ("取りやめ", .secondary)
        }
        return Text(text).font(.harness(.caption, weight: .medium)).foregroundStyle(color)
    }

    private func table(_ plan: RenamePlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("対象 \(plan.matched) 件のうち、名前が変わるのは \(plan.items.count) 件")
                .font(.harness(.caption)).foregroundStyle(.secondary)
            ForEach(Array(plan.items.prefix(shownRows).enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    Text(item.from).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(item.to).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.harness(.caption).monospaced())
            }
            if plan.items.count > shownRows {
                Text("ほか \(plan.items.count - shownRows) 件").font(.harness(.caption2)).foregroundStyle(.secondary)
            }
            if !plan.problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("このままでは適用できません", systemImage: "exclamationmark.triangle").font(.harness(.caption, weight: .semibold))
                    ForEach(plan.problems, id: \.self) { Text("・" + $0).font(.harness(.caption)) }
                }
                .foregroundStyle(.orange)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if change.status == .ready {
                Button("適用する") { store.applyRenameChange(change) }
                    .buttonStyle(.borderedProminent)
                    .disabled(change.plan?.canApply != true)
                Button("やめる") { store.discardRenameChange(change) }
            } else {
                Button("取り消す") { store.revertRenameChange(change) }
            }
        }
        .controlSize(.small)
    }
}
