import Foundation
import HarnessCore
import SwiftUI

struct FileChangeValidationPanel: View {
    @Bindable var validation: ProjectValidationSession
    @Binding var isEnabled: Bool
    let isApplied: Bool
    let requiresFinalPlanValidation: Bool
    let onRetry: () -> Void
    let replanModel: ModelSelection?
    let replanInference: any ModelInferenceProvider
    let replanProject: @MainActor () -> HarnessProject?
    let onApplyReplan: (WorkPlanReplanProposal) -> Bool
    let reviewMode: CreationLoopReviewMode
    let onRequestExternalReview: (
        ProjectValidationReport,
        BuildFailureAnalysis?
    ) -> Void

    @ViewBuilder
    var body: some View {
        if let status = validation.recoveryStatus { ValidationRecoveryNotice(status: status) }
        if isApplied, !validation.isRunning, !validation.canAutomaticallyStart, validation.report == nil {
            Button("状況を確認して再検証", action: onRetry)
                .buttonStyle(.bordered)
        }
        if validation.isSupportKnown {
            if validation.isSupported {
                supportedContent
            } else {
                Label(
                    "保存後の自動検証はSwift PackageまたはXcodeプロジェクトに対応しています。",
                    systemImage: "wrench.and.screwdriver"
                )
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var supportedContent: some View {
        if !isApplied {
            if requiresFinalPlanValidation {
                Label(
                    "計画途中では検証せず、全ファイル承認後にプロジェクト全体を必ず検証します。",
                    systemImage: "checklist.checked"
                )
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
            } else {
                Toggle(isOn: $isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("保存後に自動検証")
                            .font(.harness(.caption, weight: .semibold))
                        Text(validation.support?.automaticDescription ?? "対応する固定コマンドを実行します。")
                            .font(.harness(.caption2))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        } else if validation.isRunning {
            validationCard(color: .accentColor) {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("変更後のプロジェクト検証を実行中")
                            .font(.harness(.caption, weight: .semibold))
                        Text("完了するまでファイルの復元をロックします。")
                            .font(.harness(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("停止") { validation.stop() }
                        .controlSize(.small)
                }
            }
        } else if let report = validation.report {
            let assessment = report.succeeded ? nil : ValidationFailureClassifier.classify(
                report: report,
                analysis: validation.failureAnalysis
            )
            VStack(alignment: .leading, spacing: 10) {
                reportCard(report)
                if let assessment {
                    ValidationFailureClassificationView(assessment: assessment)
                }
                ValidationRevisionGuidanceView(
                    guidance: ValidationRevisionGuidanceBuilder.make(
                        report: report,
                        analysis: validation.failureAnalysis
                    ),
                    reviewMode: reviewMode,
                    onRequestExternalReview: {
                        onRequestExternalReview(
                            report,
                            validation.failureAnalysis
                        )
                    }
                )
                if assessment?.permitsCodeChanges == true {
                    WorkPlanReplanView(
                        model: replanModel,
                        inference: replanInference,
                        project: replanProject,
                        report: report,
                        analysis: validation.failureAnalysis,
                        onApply: onApplyReplan
                    )
                }
            }
        } else if let error = validation.errorMessage {
            validationCard(color: .orange) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(error)
                            .font(.harness(.caption, weight: .semibold))
                        Text("変更は保持されています。再検証するか、下のボタンで元に戻せます。")
                            .font(.harness(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("再検証", action: onRetry)
                        .controlSize(.small)
                }
            }
        } else {
            Label(
                "保存後の自動検証をスキップしました。",
                systemImage: "forward.fill"
            )
            .font(.harness(.caption))
            .foregroundStyle(.secondary)
        }
    }

    private func reportCard(_ report: ProjectValidationReport) -> some View {
        let color: Color = report.succeeded ? .green : .orange
        return validationCard(color: color) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: report.succeeded
                        ? "checkmark.seal.fill"
                        : "exclamationmark.triangle.fill")
                        .foregroundStyle(color)
                    Text(report.succeeded
                        ? "変更後の検証に合格しました"
                        : "変更後の検証に失敗しました")
                        .font(.harness(.caption, weight: .semibold))
                    Spacer()
                    if !report.succeeded {
                        Button("再検証", action: onRetry)
                            .controlSize(.small)
                    }
                }
                HStack(spacing: 12) {
                    ForEach(report.checks.indices, id: \.self) { index in
                        let check = report.checks[index]
                        Label(
                            "\(check.kind.displayName) · \(duration(check.duration))",
                            systemImage: check.succeeded
                                ? "checkmark.circle.fill"
                                : "xmark.circle.fill"
                        )
                        .font(.harness(.caption2))
                        .foregroundStyle(check.succeeded ? .green : .red)
                    }
                }
                if !report.succeeded {
                    Text("現在の変更は保持されています。下の「検証失敗を元に戻す」で安全に復元できます。")
                        .font(.harness(.caption2))
                        .foregroundStyle(.secondary)
                    if let output = failureOutput(report) {
                        DisclosureGroup("エラー出力") {
                            ScrollView {
                                Text(output)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 100)
                        }
                        .font(.harness(.caption2))
                    }
                }
            }
        }
    }

    private func validationCard<Content: View>(
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.18)))
    }

    private func duration(_ value: TimeInterval) -> String {
        String(format: "%.1f秒", value)
    }

    private func failureOutput(_ report: ProjectValidationReport) -> String? {
        guard let output = report.checks.first(where: { !$0.succeeded })?.output,
              !output.isEmpty else { return nil }
        return String(output.suffix(4_000))
    }
}
