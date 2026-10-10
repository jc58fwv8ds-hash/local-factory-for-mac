import HarnessCore
import SwiftUI

struct ValidationFailureAnalysisView: View {
    let analysis: BuildFailureAnalysis
    let onRequestRepair: (BuildRepairPlan, BuildRepairTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("失敗ログの解析", systemImage: "stethoscope")
                .font(.harness(.subheadline, weight: .semibold))

            if let plan = analysis.repairPlan {
                Text("\(plan.targets.count)ファイル・\(analysis.diagnostics.count)件を、1ファイルずつ承認できる修正計画にしました。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)

                ForEach(plan.targets.prefix(5)) { target in
                    targetButton(target, plan: plan)
                }

                if plan.targets.count > 5 || plan.unresolvedErrorCount > 0 {
                    Text(remainingDescription(plan))
                        .font(.harness(.caption2))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("編集対象を安全に特定できませんでした。生ログを確認し、必要ならファイル編集を手動で開いてください。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.orange.opacity(0.25)))
    }

    private func targetButton(
        _ target: BuildRepairTarget,
        plan: BuildRepairPlan
    ) -> some View {
        Button {
            onRequestRepair(plan, target)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "doc.badge.gearshape")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.relativePath)
                        .font(.harness(.caption, weight: .semibold).monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(targetSummary(target))
                        .font(.harness(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text("修正")
                    .font(.harness(.caption, weight: .semibold))
            }
            .padding(8)
            .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func targetSummary(_ target: BuildRepairTarget) -> String {
        let count = "診断\(target.diagnostics.count)件"
        guard let first = target.diagnostics.first else { return count }
        let location = first.line.map { "行\($0)" } ?? "位置不明"
        return "\(count)・\(location): \(first.message)"
    }

    private func remainingDescription(_ plan: BuildRepairPlan) -> String {
        var parts: [String] = []
        if plan.targets.count > 5 {
            parts.append("ほか\(plan.targets.count - 5)ファイル")
        }
        if plan.unresolvedErrorCount > 0 {
            parts.append("対象外・位置不明・表示上限\(plan.unresolvedErrorCount)件")
        }
        return parts.joined(separator: "・")
    }
}
