import HarnessCore
import SwiftUI

struct ArtifactCreationPlanResumeNotice: View {
    let plan: ArtifactCreationPlan
    let onResume: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("進行中の成果物計画", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text("\(plan.completedCount)/\(plan.targets.count)")
                    .font(.harness(.caption2).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(plan.isFullyApplied
                ? "全ファイルを承認済みです。現在のソースをプロジェクト全体で検証できます。"
                : "次は\(plan.currentTarget?.relativePath ?? plan.nextTarget?.relativePath ?? "未対応ファイル")を独立した差分として再開します。")
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack {
                Button(plan.isFullyApplied ? "最終検証" : "計画を再開", action: onResume)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("計画記録を破棄", action: onDiscard)
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
