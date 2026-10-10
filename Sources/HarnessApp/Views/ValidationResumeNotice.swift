import HarnessCore
import SwiftUI

struct ValidationResumeNotice: View {
    let checkpoint: ProjectOperationCheckpoint
    let onResume: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("中断したプロジェクト検証", systemImage: "pause.circle.fill")
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(checkpoint.updatedAt, style: .relative)
                    .font(.harness(.caption2).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("前回の検証は完了前に終了しました。検証画面で保存済み記録を確認してから、検証し直せます。")
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)

            Text("再開用の記録と詳細な検証結果は、別に管理しています。")
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)

            HStack {
                Button("再検証する", action: onResume)
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
