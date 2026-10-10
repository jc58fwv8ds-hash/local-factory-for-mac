import HarnessCore
import SwiftUI

struct ArtifactCreationPlanPanel: View {
    @Bindable var session: FileChangeSession
    let onProgress: (ArtifactCreationPlan) -> Void

    @ViewBuilder
    var body: some View {
        if let plan = session.artifactPlan,
           let current = plan.currentTarget {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("段階的な成果物計画", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.harness(.caption, weight: .semibold))
                    Spacer()
                    Text("\(plan.completedCount)/\(plan.targets.count)ファイル")
                        .font(.harness(.caption2).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: session.isApplied
                        ? "checkmark.circle.fill"
                        : "doc.badge.plus")
                        .foregroundStyle(Color.accentColor)
                    Text(current.relativePath)
                        .font(.harness(.caption).monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if session.canContinueArtifactPlan {
                        Button("次の新規ファイル") {
                            session.continueToNextArtifactTarget()
                            if let plan = session.artifactPlan { onProgress(plan) }
                        }
                        .controlSize(.small)
                    }
                }

                Text(statusDescription(plan))
                    .font(.harness(.caption2))
                    .foregroundStyle(.secondary)
            }
            .padding(9)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.accentColor.opacity(0.16)))
        }
    }

    private func statusDescription(_ plan: ArtifactCreationPlan) -> String {
        if plan.isFullyApplied {
            return "全ファイルを承認しました。最後にプロジェクト全体を検証します。"
        }
        if session.isApplied {
            return "このファイルは承認済みです。次も独立した差分として確認します。"
        }
        return "一括保存は行いません。現在の1ファイルだけを作成します。"
    }
}
