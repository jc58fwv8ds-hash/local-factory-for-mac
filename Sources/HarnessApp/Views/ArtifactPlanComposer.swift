import HarnessCore
import SwiftUI

struct ArtifactPlanComposer: View {
    @Bindable var planner: ArtifactPlanSession
    let existingPaths: [String]
    let onStart: (ArtifactCreationPlan) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("複数ファイルの成果物計画", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.harness(.headline))
            Text("ローカルAIが目的を2〜8件の新規ファイルへ分解します。内容は1件ずつ差分確認し、一括保存しません。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(
                "例：設定を読み込んで検証する小さなSwift機能を追加して",
                text: $planner.instruction,
                axis: .vertical
            )
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)
            .disabled(planner.isGenerating)

            HStack {
                Button {
                    planner.isGenerating
                        ? planner.stop()
                        : planner.generate(existingPaths: existingPaths)
                } label: {
                    Label(
                        planner.isGenerating ? "停止" : "AIで計画を作成",
                        systemImage: planner.isGenerating ? "stop.fill" : "sparkles"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!planner.isGenerating && !planner.canGenerate)
                if planner.isGenerating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            if let plan = planner.plan {
                planPreview(plan)
            }
            if let error = planner.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.harness(.caption))
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(18)
    }

    private func planPreview(_ plan: ArtifactCreationPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("計画プレビュー")
                    .font(.harness(.subheadline, weight: .semibold))
                Spacer()
                Text("\(plan.targets.count)ファイル")
                    .font(.harness(.caption).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(plan.targets.enumerated()), id: \.element.id) { index, target in
                HStack(alignment: .top, spacing: 9) {
                    Text("\(index + 1)")
                        .font(.harness(.caption2).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.relativePath)
                            .font(.harness(.caption, weight: .semibold).monospaced())
                        Text(target.instruction)
                            .font(.harness(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
            Button("この計画を1ファイルずつ開始") { onStart(plan) }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.16)))
    }
}
