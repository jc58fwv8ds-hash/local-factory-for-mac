import HarnessCore
import SwiftUI

struct FileRepairPlanPanel: View {
    @Bindable var session: FileChangeSession
    let onProgress: (BuildRepairProgress) -> Void

    @ViewBuilder
    var body: some View {
        if let plan = session.repairPlan,
           let current = session.currentRepairTarget {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("段階的な修正計画", systemImage: "list.number")
                        .font(.harness(.caption, weight: .semibold))
                    Spacer()
                    Text("\(completedCount)/\(plan.targets.count)ファイル")
                        .font(.harness(.caption2).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: currentSymbol)
                        .foregroundStyle(currentColor)
                    Text(current.relativePath)
                        .font(.harness(.caption).monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if session.canContinueRepairPlan {
                        Button("次の未対応ファイル") {
                            Task {
                                await session.continueToNextRepairTarget()
                                if let progress = session.repairProgress {
                                    onProgress(progress)
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                }

                Text(statusDescription)
                    .font(.harness(.caption2))
                    .foregroundStyle(.secondary)
            }
            .padding(9)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.accentColor.opacity(0.16)))
        }
    }

    private var completedCount: Int {
        guard let plan = session.repairPlan else { return 0 }
        return plan.targets.filter { session.completedRepairTargetIDs.contains($0.id) }.count
    }

    private var currentSymbol: String {
        if session.validation.report?.succeeded == true { return "checkmark.seal.fill" }
        return session.isApplied ? "checkmark.circle.fill" : "pencil.circle.fill"
    }

    private var currentColor: Color {
        session.validation.report?.succeeded == true ? .green : Color.accentColor
    }

    private var statusDescription: String {
        if session.validation.report?.succeeded == true {
            return "再検証に合格しました。残りの旧診断は解消済みとして計画を終了できます。"
        }
        if session.validation.isRunning {
            return "保存した変更を検証中です。完了後に次の対象へ進めます。"
        }
        if session.isApplied, session.nextRepairTarget != nil {
            return "このファイルは承認済みです。次も別の差分として確認します。"
        }
        if session.isApplied {
            return "計画内の対象をすべて承認しました。再検証結果を確認してください。"
        }
        return "一括保存は行いません。このファイルの差分だけを先に承認します。"
    }
}
