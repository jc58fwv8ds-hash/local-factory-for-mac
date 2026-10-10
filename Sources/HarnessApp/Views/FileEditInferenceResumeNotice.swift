import HarnessCore
import SwiftUI

struct FileEditInferenceResumeNotice: View {
    let checkpoint: ProjectOperationCheckpoint
    let onReopen: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("中断したファイル変更案", systemImage: "pause.circle.fill")
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(checkpoint.updatedAt, style: .relative)
                    .font(.harness(.caption2).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("途中のAI出力とファイル内容は保存していません。安全な編集画面を開き、現在のソースへ指示を入力し直せます。")
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
