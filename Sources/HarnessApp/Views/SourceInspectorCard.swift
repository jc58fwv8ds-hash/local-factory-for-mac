import HarnessCore
import SwiftUI

struct SourceInspectorCard: View {
    let record: ProjectRecord
    let isInspecting: Bool
    let sourceChange: SourceChangeSummary?
    let onConnect: () -> Void
    let onCreateIPhoneApp: () -> Void
    let onInspect: () -> Void
    let onEdit: () -> Void
    let onValidate: () -> Void
    let onResumeValidation: () -> Void
    let onResumeFileEdit: () -> Void
    let onDiscardOperation: () -> Void
    let onResumeArtifactPlan: () -> Void
    let onDiscardArtifactPlan: () -> Void
    let onResumeRepair: () -> Void
    let onDiscardRepair: () -> Void
    let onSimulator: () -> Void
    let onPhysicalDevice: () -> Void
    let onShowCheckpoints: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("ソース", systemImage: "folder.fill")
                    .font(.harness(.subheadline, weight: .semibold))
                Spacer()
                if record.sourceLocation == nil {
                    Text("未接続")
                        .font(.harness(.caption2, weight: .semibold))
                        .foregroundStyle(.orange)
                } else {
                    SourceHealthLabel(inspection: record.sourceInspection)
                }
            }

            if let sourceLocation = record.sourceLocation {
                connectedContent(sourceLocation: sourceLocation)
            } else {
                disconnectedContent
            }
        }
        .inspectorCard()
    }

    @ViewBuilder
    private func connectedContent(sourceLocation: String) -> some View {
        Text(sourceLocation)
            .font(.harness(.caption2).monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)

        Label(sourceContextLimitLabel, systemImage: "lock.doc")
            .font(.harness(.caption2, weight: .medium))
            .foregroundStyle(.green)

        if isInspecting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("読み取り専用で確認中…")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
        } else if let inspection = record.sourceInspection {
            inspectionContent(inspection)
        } else {
            Text("まだ診断していません。ファイル内容は変更せず、構成だけを確認します。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let sourceChange {
            SourceChangeNotice(summary: sourceChange)
        }

        if let checkpoint = record.project.operationCheckpoint,
           checkpoint.operation == .projectValidation,
           record.project.repairResumeState == nil {
            ValidationResumeNotice(
                checkpoint: checkpoint,
                onResume: onResumeValidation,
                onDiscard: onDiscardOperation
            )
        }

        if let checkpoint = record.project.operationCheckpoint,
           checkpoint.operation == .fileEditInference {
            FileEditInferenceResumeNotice(
                checkpoint: checkpoint,
                onReopen: onResumeFileEdit,
                onDiscard: onDiscardOperation
            )
        }

        if let checkpoint = record.project.operationCheckpoint,
           checkpoint.operation == .artifactPlanning {
            ArtifactPlanningResumeNotice(
                checkpoint: checkpoint,
                onReopen: onResumeFileEdit,
                onDiscard: onDiscardOperation
            )
        }

        if let plan = record.project.artifactCreationPlan {
            ArtifactCreationPlanResumeNotice(
                plan: plan,
                onResume: onResumeArtifactPlan,
                onDiscard: onDiscardArtifactPlan
            )
        }

        if let repairResumeState = record.project.repairResumeState {
            RepairResumeNotice(
                state: repairResumeState,
                onResume: onResumeRepair,
                onDiscard: onDiscardRepair
            )
        }

        Button("ファイルを安全に編集", action: onEdit)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isInspecting)
            .accessibilityIdentifier(HarnessAccessibilityID.sourceEdit)

        if canValidate {
            Button("プロジェクトを検証", action: onValidate)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isInspecting)
                .accessibilityIdentifier(HarnessAccessibilityID.sourceValidate)
        }

        if canUseSimulator {
            Button("Simulatorを確認", action: onSimulator)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isInspecting)

            Button("実機iPhoneで確認", action: onPhysicalDevice)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isInspecting)
                .accessibilityIdentifier(HarnessAccessibilityID.physicalDeviceOpen)
        }

        if !record.project.fileCheckpoints.isEmpty {
            Button(action: onShowCheckpoints) {
                Label(
                    "Git復元ポイント \(record.project.fileCheckpoints.count)",
                    systemImage: "clock.arrow.circlepath"
                )
            }
            .buttonStyle(.plain)
            .font(.harness(.caption, weight: .medium))
            .foregroundStyle(Color.accentColor)
        }

        HStack {
            Button(record.sourceInspection == nil ? "ソースを診断" : "再診断", action: onInspect)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isInspecting)
            Button("接続解除", action: onDisconnect)
                .buttonStyle(.plain)
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
        }
    }

    private var disconnectedContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("制作物のフォルダを接続すると、構成と利用技術を安全に確認できます。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("ファイルは変更しません", systemImage: "eye")
                .font(.harness(.caption2, weight: .medium))
                .foregroundStyle(.green)
            Button("フォルダを接続", action: onConnect)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("iPhoneアプリの土台を作る", action: onCreateIPhoneApp)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(HarnessAccessibilityID.sourceCreateIPhoneApp)
        }
    }

    private var sourceContextLimitLabel: String {
        guard let model = record.project.selectedModel else {
            return "AIへの参照は読み取り専用・モデル選択後に上限決定"
        }
        let budget = SourceContextBudgetPolicy.budget(for: model)
        return "AI参照: 最大\(budget.maxFiles)ファイル・\(budget.maxTotalCharacters)文字"
    }

    private var canValidate: Bool {
        guard let inspection = record.sourceInspection else { return false }
        return inspection.manifestNames.contains {
            $0.lowercased() == "package.swift"
        } || inspection.technologies.contains(.xcode)
    }

    private var canUseSimulator: Bool {
        record.sourceInspection?.technologies.contains(.xcode) == true
    }

    @ViewBuilder
    private func inspectionContent(_ inspection: SourceInspection) -> some View {
        HStack(spacing: 8) {
            SourceMetric(value: "\(inspection.fileCount)", label: "ファイル")
            SourceMetric(value: inspection.sizeLabel, label: "容量")
            SourceMetric(value: inspection.hasGitRepository ? "あり" : "なし", label: "Git")
        }

        if !inspection.technologies.isEmpty {
            HStack(spacing: 5) {
                ForEach(Array(inspection.technologies.prefix(3))) { technology in
                    Text(technology.displayName)
                        .font(.harness(.caption2, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.08), in: Capsule())
                }
            }
        }

        Text("最終確認: \(inspection.scannedAt, style: .relative)")
            .font(.harness(.caption2))
            .foregroundStyle(.tertiary)
    }
}

private struct SourceHealthLabel: View {
    let inspection: SourceInspection?

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.harness(.caption2, weight: .semibold))
            .foregroundStyle(color)
    }

    private var title: String {
        switch inspection?.health {
        case .healthy: "確認済み"
        case .limited: "一部確認"
        case .missing: "見つかりません"
        case .unreadable: "読取不可"
        case nil: "未診断"
        }
    }

    private var symbol: String {
        switch inspection?.health {
        case .healthy: "checkmark.circle.fill"
        case .limited: "ellipsis.circle.fill"
        case .missing: "questionmark.folder.fill"
        case .unreadable: "exclamationmark.triangle.fill"
        case nil: "clock"
        }
    }

    private var color: Color {
        switch inspection?.health {
        case .healthy: .green
        case .limited: .orange
        case .missing, .unreadable: .red
        case nil: .secondary
        }
    }
}

private struct SourceMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.harness(.caption, weight: .semibold))
                .lineLimit(1)
            Text(label)
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
}
