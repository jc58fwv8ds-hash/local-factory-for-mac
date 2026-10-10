import HarnessCore
import SwiftUI

struct InferenceResumeNotice: View {
    let checkpoint: ProjectOperationCheckpoint
    let canResume: Bool
    let onResume: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("中断したAI応答", systemImage: "sparkles.rectangle.stack.fill")
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(checkpoint.updatedAt, style: .relative)
                    .font(.harness(.caption2).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(resumeDescription)
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)

            Text("途中の回答やソース内容は保存していません。既存の指示も重複追加しません。")
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)

            HStack {
                Button("同じ指示を再実行", action: onResume)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canResume)
                Button("記録を破棄", action: onDiscard)
                    .buttonStyle(.plain)
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.18)))
    }

    private var resumeDescription: String {
        canResume
            ? "前回の生成は完了前に終了しました。保存済みの指示から最初から生成し直せます。"
            : "再実行するにはAIモデルを接続してください。保存済みの指示は会話に残っています。"
    }
}
