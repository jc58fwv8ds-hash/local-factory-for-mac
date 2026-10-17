import HarnessCore
import SwiftUI

struct ComputerOperatorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: WorkspaceStore
    @State private var showsExecutionConfirmation = false

    private var session: ComputerOperatorSession { store.computerOperator }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    capabilityStrip
                    safetyNotice
                    if let notice = session.recoveryNotice {
                        recoverySection(notice)
                    }
                    instructionComposer
                    stepByStepSection
                    if let plan = session.plan { planSection(plan) }
                    if !session.results.isEmpty { resultSection }
                    if let summary = session.resultSummary {
                        resultSummarySection(summary)
                    }
                    if let error = session.errorMessage { errorBanner(error) }
                }
                .padding(22)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 720)
        .confirmationDialog(
            "この操作計画を実行しますか？",
            isPresented: $showsExecutionConfirmation,
            titleVisibility: .visible
        ) {
            Button("残り\(session.remainingStepCount)手順を実行") {
                store.executeComputerOperatorPlan()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("検索語はGoogleへ送られ、ボタン操作は表示された対象だけに1回実行されます。削除・購入・公開・文字入力は対象外です。")
        }
        .onAppear {
            session.restore(project: store.project)
        }
        .onChange(of: store.project.id) {
            session.restore(project: store.project)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer.and.macbook")
                .font(.harness(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Computer Operator")
                    .font(.harness(.title2, weight: .semibold))
                Text("いつもの言葉を、安全な操作計画にしてから実行します")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("完了") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(session.isBusy)
        }
        .padding(18)
    }

    private var capabilityStrip: some View {
        HStack(spacing: 10) {
            capability("ビルドとテスト", "checkmark.seal", true)
            capability("Web検索", "magnifyingglass", true)
            capability(
                "画面の読取・操作",
                "cursorarrow.click",
                session.hasAccessibilityPermission
            )
        }
    }

    private func capability(
        _ title: String,
        _ symbol: String,
        _ available: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(available ? Color.accentColor : .orange)
            Text(title)
                .font(.harness(.caption, weight: .semibold))
            Spacer(minLength: 0)
            Image(systemName: available ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(available ? .green : .orange)
        }
        .padding(11)
        .frame(maxWidth: .infinity)
        .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    private var safetyNotice: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 5) {
                Text("裏側で動いても、勝手には実行しません")
                    .font(.harness(.subheadline, weight: .semibold))
                Text("AIは計画だけを作り、実行前に対象と理由を表示します。削除・購入・公開・ログイン・文字入力はこの版では実行できません。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                if !session.hasAccessibilityPermission {
                    Button("macOSのアクセシビリティ設定を開く") {
                        session.openAccessibilitySettings()
                    }
                    .buttonStyle(.link)
                    .font(.harness(.caption))
                }
            }
        }
        .padding(13)
        .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var instructionComposer: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("何をしてほしい？")
                .font(.harness(.headline))
            TextEditor(text: Binding(
                get: { session.instruction },
                set: { session.instruction = $0 }
            ))
            .font(.harness(.body))
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(minHeight: 88, maxHeight: 130)
            .background(.background, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(.quaternary))
            .accessibilityIdentifier(HarnessAccessibilityID.computerOperatorInstruction)
            Text("例：『プロジェクトをテストして、Appleの設計資料を検索して』")
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)
        }
    }

    private func recoverySection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("前回の操作を安全に復旧", systemImage: "arrow.clockwise.circle.fill")
                .font(.harness(.subheadline, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
            if session.uncertainStepIndex != nil {
                HStack {
                    Button("この手順をもう一度行う") {
                        session.resolveUncertainStep(retry: true)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("この手順は飛ばす") {
                        session.resolveUncertainStep(retry: false)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func planSection(_ plan: ComputerOperationPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("実行前の操作計画", systemImage: "list.bullet.clipboard")
                .font(.harness(.headline))
            Text(plan.summary)
                .font(.harness(.subheadline))
            VStack(spacing: 0) {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 11) {
                        Text(stepMarker(for: index))
                            .font(.harness(.caption, weight: .bold).monospacedDigit())
                            .frame(width: 24, height: 24)
                            .background(
                                stepMarkerColor(for: index)
                                    .opacity(0.12),
                                in: Circle()
                            )
                        Image(systemName: step.kind.systemImage)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.kind.displayName)
                                .font(.harness(.subheadline, weight: .semibold))
                            Text(step.detail)
                                .font(.harness(.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    if index < plan.steps.count - 1 { Divider().padding(.leading, 47) }
                }
            }
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        }
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("操作履歴")
                .font(.harness(.headline))
            ForEach(session.results) { result in
                DisclosureGroup {
                    Text(result.message)
                        .font(.harness(.caption).monospaced())
                        .textSelection(.enabled)
                        .padding(.top, 6)
                } label: {
                    Label(
                        result.step.kind.displayName,
                        systemImage: result.wasSkipped
                            ? "arrowshape.turn.up.right.circle.fill"
                            : result.succeeded
                            ? "checkmark.circle.fill"
                            : "xmark.circle.fill"
                    )
                    .foregroundStyle(
                        result.wasSkipped ? .orange : (result.succeeded ? .green : .red)
                    )
                }
                .padding(11)
                .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func resultSummarySection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Local Factoryからの説明", systemImage: "text.bubble.fill")
                .font(.harness(.headline))
                .foregroundStyle(Color.accentColor)
            ExplainedResponseText(
                text: summary,
                model: store.project.selectedModel,
                service: store.termExplanationService,
                isSuspended: store.isGenerating || session.isBusy,
                style: .body
            )
            .id(store.project.id)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.harness(.caption))
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            if session.plan != nil {
                Button("計画を作り直す") { session.reset() }
                    .disabled(session.isBusy)
            }
            Spacer()
            if session.isBusy {
                Button("停止") { session.stop() }
                    .foregroundStyle(.orange)
                ProgressView()
                    .controlSize(.small)
                Text(busyMessage)
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            } else if session.plan == nil {
                Button("安全な操作案を作る") {
                    store.makeComputerOperatorPlan()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !session.canPlan
                        || store.interactionBlocker(for: .prepareComputerOperation) != nil
                )
                .accessibilityIdentifier(HarnessAccessibilityID.computerOperatorPlan)
            } else {
                Button("この計画を実行") { showsExecutionConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !session.canRun
                            || store.interactionBlocker(for: .executeComputerOperation) != nil
                    )
                    .accessibilityIdentifier(HarnessAccessibilityID.computerOperatorRun)
            }
        }
        .padding(16)
    }

    private var busyMessage: String {
        if session.isPlanning { return "操作案を作っています…" }
        if session.isRunning { return "順番に実行しています…" }
        return "結果をわかりやすく整理しています…"
    }

    private func stepMarker(for index: Int) -> String {
        if session.skippedStepIndexes.contains(index) { return "—" }
        return index < session.nextStepIndex ? "✓" : "\(index + 1)"
    }

    private func stepMarkerColor(for index: Int) -> Color {
        if session.skippedStepIndexes.contains(index) { return .orange }
        return index < session.nextStepIndex ? .green : .accentColor
    }
}
