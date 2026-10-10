import HarnessCore
import SwiftUI

struct RepairResumeNotice: View {
    let state: RepairResumeState
    let onResume: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("中断中の修正計画", systemImage: "arrow.clockwise.circle.fill")
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text("\(state.completedCount)/\(state.targetPaths.count)ファイル")
                    .font(.harness(.caption2).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let currentPath = state.currentPath {
                Text(currentPath)
                    .font(.harness(.caption2).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text("ログやAI指示は保存していません。最新状態を再検証してから修正計画を作り直します。")
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)

            HStack {
                Button("再検証して再開", action: onResume)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("記録を破棄", action: onDiscard)
                    .buttonStyle(.plain)
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.accentColor.opacity(0.18)))
    }
}
