import HarnessCore
import SwiftUI

struct ModelAcquisitionResumeNotice: View {
    let checkpoint: ModelAcquisitionCheckpoint
    let canResume: Bool
    let onResume: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("中断したモデル取得", systemImage: "arrow.down.circle.fill")
                    .font(.harness(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(checkpoint.updatedAt, style: .relative)
                    .font(.harness(.caption2))
                    .foregroundStyle(.secondary)
            }

            Text("\(checkpoint.request.displayName) ・ \(checkpoint.request.runtime.rawValue)")
                .font(.harness(.caption, weight: .medium))
            Text(resumeDescription)
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("取得を再開", action: onResume)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canResume)
                Button("記録を破棄", role: .destructive, action: onDiscard)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
    }

    private var resumeDescription: String {
        if canResume {
            "モデルやログをLocal Factoryへ複製せず、ランタイム側の取得済みデータを利用して再実行します。"
        } else {
            "\(checkpoint.request.runtime.rawValue)が見つかりません。再導入後に再開できます。"
        }
    }
}
