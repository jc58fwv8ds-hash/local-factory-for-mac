import HarnessCore
import SwiftUI

struct ArtifactPlanningResumeNotice: View {
    let checkpoint: ProjectOperationCheckpoint
    let onReopen: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("中断した成果物計画の生成", systemImage: "pause.circle.fill")
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(checkpoint.updatedAt, style: .relative)
                    .font(.harness(.caption2).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("途中のAI出力と制作指示は複製していません。編集画面から目的を入力し直せます。")
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)
            HStack {
                Button("編集画面を開く", action: onReopen)
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
