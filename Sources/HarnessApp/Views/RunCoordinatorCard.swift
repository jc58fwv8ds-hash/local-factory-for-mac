import HarnessCore
import SwiftUI

struct RunCoordinatorCard: View {
    @Bindable var store: WorkspaceStore
    let onBegin: () -> Void
    let onContinue: () -> Void
    let onValidate: () -> Void

    private var state: RunCoordinatorState { store.project.runCoordinator }

    private var currentItem: WorkItem? {
        guard let id = state.currentWorkItemID else { return nil }
        return store.project.workItems.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("連続制作", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.harness(.subheadline, weight: .semibold))
                Spacer()
                Text("\(state.approvedCycleCount)項目を確認済み")
                    .font(.harness(.caption2).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("1項目ずつ、差分確認と検証を通して進めます。保存や完了は確認なしでは行いません。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.phase.displayName)
                    .font(.harness(.caption, weight: .semibold))
                if let currentItem {
                    Text(currentItem.title)
                        .font(.harness(.subheadline, weight: .medium))
                        .lineLimit(2)
                }
                Text("連続サイクル \(state.cycleCountSinceConfirmation) / \(state.maximumCycles)")
                    .font(.harness(.caption2).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let guidance {
                Label(guidance, systemImage: guidanceSymbol)
                    .font(.harness(.caption))
                    .foregroundStyle(guidanceColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(primaryTitle, action: performPrimaryAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier(HarnessAccessibilityID.runCoordinatorPrimary)

                if canPause {
                    Button("一時停止") { store.pauseRunCoordinator() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier(HarnessAccessibilityID.runCoordinatorPause)
                }
            }
        }
        .inspectorCard()
    }

    private var primaryTitle: String {
        switch state.phase {
        case .inactive, .readyForNextItem: "次の1項目を始める"
        case .awaitingChange: "変更を続ける"
        case .awaitingValidation: "変更を検証"
        case .awaitingRepair: "修正を続ける"
        case .awaitingReview: "この項目を完了にする"
        case .readyForFinalValidation: "全体を最終検証"
        case .paused, .blocked: "内容を確認して再開"
        }
    }

    private var canPause: Bool {
        state.phase == .awaitingChange || state.phase == .awaitingRepair
    }

    private var guidance: String? {
        switch state.phase {
        case .awaitingValidation:
            "保存した変更を、固定されたビルドとテストで確認してから次へ進みます。"
        case .awaitingRepair:
            "直前の検証は未合格です。Local Factoryの修正ガイドに沿って、原因を1件ずつ直してね。"
        case .awaitingReview: "検証は成功しています。変更内容を確認してから完了にしてね。"
        case .readyForFinalValidation: "すべての制作項目を確認しました。最後に全体を検証します。"
        case .blocked where state.stopReason == .repeatedFailure:
            RunCoordinatorBlocker.repeatedFailure.guidance
        case .blocked: RunCoordinatorBlocker.workItemUnavailable.guidance
        case .paused where state.stopReason == .iterationLimit:
            RunCoordinatorBlocker.iterationLimit.guidance
        case .paused: "現在の項目を残したまま停止しています。"
        default: nil
        }
    }

    private var guidanceSymbol: String {
        state.phase == .awaitingReview || state.phase == .readyForFinalValidation
            ? "checkmark.seal" : "exclamationmark.triangle"
    }

    private var guidanceColor: Color {
        state.phase == .awaitingReview || state.phase == .readyForFinalValidation
            ? .green : .orange
    }

    private func performPrimaryAction() {
        switch state.phase {
        case .inactive, .readyForNextItem: onBegin()
        case .awaitingChange, .awaitingRepair, .paused, .blocked: onContinue()
        case .awaitingValidation, .readyForFinalValidation: onValidate()
        case .awaitingReview: store.approveCurrentRunItem()
        }
    }
}
