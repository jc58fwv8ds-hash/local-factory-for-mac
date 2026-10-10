import HarnessCore
import SwiftUI

struct WorkPlanReplanView: View {
    @State private var session: WorkPlanReplanSession
    @State private var isConfirmingAdoption = false
    let project: @MainActor () -> HarnessProject?
    let report: ProjectValidationReport
    let analysis: BuildFailureAnalysis?
    let onApply: (WorkPlanReplanProposal) -> Bool

    init(
        model: ModelSelection?,
        inference: any ModelInferenceProvider,
        project: @escaping @MainActor () -> HarnessProject?,
        report: ProjectValidationReport,
        analysis: BuildFailureAnalysis?,
        onApply: @escaping (WorkPlanReplanProposal) -> Bool
    ) {
        _session = State(
            initialValue: WorkPlanReplanSession(model: model, inference: inference)
        )
        self.project = project
        self.report = report
        self.analysis = analysis
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("制作計画の安全な見直し", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.harness(.subheadline, weight: .semibold))
            Text("検査結果を短く整理し、既存の完成条件を変えずに順序と不足項目を提案します。採用するまで計画は変わりません。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)

            if session.isGenerating {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("ローカルAIが小さな確認単位へ整理しています…")
                        .font(.harness(.caption))
                    Spacer()
                    Button("停止") { session.stop() }
                        .controlSize(.small)
                        .accessibilityIdentifier(HarnessAccessibilityID.workPlanReplanStop)
                }
            } else if let proposal = session.proposal {
                proposalContent(proposal)
            } else {
                Button {
                    guard let current = project() else { return }
                    session.generate(
                        project: current,
                        report: report,
                        analysis: analysis
                    )
                } label: {
                    Label("AIに見直し案を作ってもらう", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(!session.canGenerate || project() == nil)
                .accessibilityIdentifier(HarnessAccessibilityID.workPlanReplanGenerate)

                if !session.canGenerate {
                    Text("先にこのプロジェクトへローカルAIモデルを接続してください。")
                        .font(.harness(.caption2))
                        .foregroundStyle(.secondary)
                }
            }

            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.harness(.caption))
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.16)))
        .onDisappear { session.stop() }
        .confirmationDialog(
            "この見直し案を制作計画へ反映しますか？",
            isPresented: $isConfirmingAdoption,
            titleVisibility: .visible
        ) {
            Button("確認して採用") { adoptProposal() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("既存の完成条件は保ち、表示した順序と追加項目だけを反映します。検証結果は更新後に取り直します。")
        }
    }

    private func proposalContent(_ proposal: WorkPlanReplanProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(proposal.summary)
                .font(.harness(.caption))
            if !proposal.uncertainties.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("まだ確かでない点", systemImage: "questionmark.diamond")
                        .font(.harness(.caption, weight: .semibold))
                    ForEach(proposal.uncertainties, id: \.self) { item in
                        Text("• \(item)")
                            .font(.harness(.caption2))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(proposal.items.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.harness(.caption2, weight: .bold).monospacedDigit())
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.title)
                                    .font(.harness(.caption, weight: .semibold))
                                if item.isNew {
                                    Text("追加")
                                        .font(.harness(.caption2, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            if !item.detail.isEmpty {
                                Text(item.detail)
                                    .font(.harness(.caption2))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Label("AI案は未検証です。採用後もビルドとテストの合格が必要です。", systemImage: "checkmark.shield")
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)
            HStack {
                Button("破棄") { session.discard() }
                    .controlSize(.small)
                    .accessibilityIdentifier(HarnessAccessibilityID.workPlanReplanDiscard)
                Spacer()
                Button("この案を採用") { isConfirmingAdoption = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier(HarnessAccessibilityID.workPlanReplanAdopt)
            }
        }
    }

    private func adoptProposal() {
        guard let proposal = session.proposal else { return }
        if onApply(proposal) {
            session.discard()
        }
    }
}
