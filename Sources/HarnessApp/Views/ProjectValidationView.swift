import HarnessCore
import SwiftUI

struct ProjectValidationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: ProjectValidationSession
    let model: ModelSelection?
    let inference: any ModelInferenceProvider
    let project: @MainActor () -> HarnessProject?
    let onApplyReplan: (WorkPlanReplanProposal) -> Bool
    let onStart: @MainActor () -> Void
    let onComplete: @MainActor @Sendable (ProjectValidationReport) -> Void
    let onRequestRepair: (BuildRepairPlan, BuildRepairTarget) -> Void
    let reviewMode: CreationLoopReviewMode
    let onRequestExternalReview: (
        ProjectValidationReport,
        BuildFailureAnalysis?
    ) -> Void
    let startsAutomatically: Bool
    @State private var didRequestAutomaticStart = false

    init(
        rootPath: String,
        provider: any ProjectValidating,
        model: ModelSelection?,
        inference: any ModelInferenceProvider,
        project: @escaping @MainActor () -> HarnessProject?,
        onApplyReplan: @escaping (WorkPlanReplanProposal) -> Bool,
        startsAutomatically: Bool = false,
        onStart: @escaping @MainActor () -> Void,
        onComplete: @escaping @MainActor @Sendable (ProjectValidationReport) -> Void,
        onRequestRepair: @escaping (BuildRepairPlan, BuildRepairTarget) -> Void,
        reviewMode: CreationLoopReviewMode,
        onRequestExternalReview: @escaping (
            ProjectValidationReport,
            BuildFailureAnalysis?
        ) -> Void
    ) {
        _session = State(
            initialValue: ProjectValidationSession(
                rootPath: rootPath,
                provider: provider
            )
        )
        self.model = model
        self.inference = inference
        self.project = project
        self.onApplyReplan = onApplyReplan
        self.onStart = onStart
        self.onComplete = onComplete
        self.onRequestRepair = onRequestRepair
        self.reviewMode = reviewMode
        self.onRequestExternalReview = onRequestExternalReview
        self.startsAutomatically = startsAutomatically
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    commandNotice
                    if let status = session.recoveryStatus { ValidationRecoveryNotice(status: status) }
                    content
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 600)
        .task {
            if !session.isSupportKnown {
                await session.detectSupport()
            }
            if startsAutomatically,
               !didRequestAutomaticStart,
                session.isSupported, session.canAutomaticallyStart {
                didRequestAutomaticStart = true
                session.startAutomatically(onStart: onStart, onComplete: onComplete)
            }
        }
        .onDisappear { session.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.harness(.title2))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("プロジェクト検証")
                    .font(.harness(.headline))
                Text(session.support?.headerDescription ?? "検証方式を確認しています…")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("完了") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var commandNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("実行するコマンド", systemImage: "terminal")
                .font(.harness(.subheadline, weight: .semibold))
            Text(session.support?.commandSummary ?? "確認中…")
                .font(.harness(.caption).monospaced())
            if let containerName = session.support?.containerName {
                Label(containerName, systemImage: "shippingbox")
                    .font(.harness(.caption2).monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("任意のシェルコマンドや公開・署名処理は実行しません。各処理は3分で停止します。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var content: some View {
        if session.isRunning {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(session.support?.system == .xcode
                    ? "Xcodeのビルドとテストを実行しています…"
                    : "ビルドを実行しています…")
                    .font(.harness(.headline))
                Text("依存関係の解決には時間がかかる場合があります。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 80)
        } else if let report = session.report {
            let assessment = report.succeeded ? nil : ValidationFailureClassifier.classify(
                report: report,
                analysis: session.failureAnalysis
            )
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    report.succeeded ? "すべての検証に合格" : "検証結果を確認してください",
                    systemImage: report.succeeded
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.harness(.headline))
                .foregroundStyle(report.succeeded ? .green : .orange)

                ForEach(Array(report.checks.enumerated()), id: \.offset) { _, check in
                    ValidationCheckCard(check: check)
                }

                if let assessment {
                    ValidationFailureClassificationView(assessment: assessment)
                }

                if assessment?.permitsCodeChanges == true,
                   let analysis = session.failureAnalysis {
                    ValidationFailureAnalysisView(
                        analysis: analysis,
                        onRequestRepair: requestRepair
                    )
                }

                ValidationRevisionGuidanceView(
                    guidance: ValidationRevisionGuidanceBuilder.make(
                        report: report,
                        analysis: session.failureAnalysis
                    ),
                    reviewMode: reviewMode,
                    onRequestExternalReview: {
                        dismiss()
                        onRequestExternalReview(report, session.failureAnalysis)
                    }
                )

                if assessment?.permitsCodeChanges == true {
                    WorkPlanReplanView(
                        model: model,
                        inference: inference,
                        project: project,
                        report: report,
                        analysis: session.failureAnalysis,
                        onApply: onApplyReplan
                    )
                }
            }
        } else if session.isSupportKnown && !session.isSupported {
            ContentUnavailableView(
                "検証対象を確認できません",
                systemImage: "questionmark.folder",
                description: Text("Package.swiftまたはXcodeプロジェクトを確認してください。")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 70)
        } else {
            ContentUnavailableView(
                "検証を開始できます",
                systemImage: "hammer",
                description: Text(session.support?.idleDescription ?? "検証方式を確認しています。")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 70)
        }

        if let errorMessage = session.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.harness(.caption))
                .foregroundStyle(.red)
        }
    }

    private var footer: some View {
        HStack {
            Text(session.rootPath)
                .font(.harness(.caption2).monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(session.isRunning
                ? "停止"
                : session.support?.startButtonTitle ?? "確認中…") {
                if session.isRunning {
                    session.stop()
                } else {
                    startValidation()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(session.isRunning ? .orange : Color.accentColor)
            .disabled(!session.isRunning && !session.isSupported)
            .accessibilityIdentifier(HarnessAccessibilityID.projectValidationRun)
        }
        .padding(16)
    }

    private func requestRepair(
        _ plan: BuildRepairPlan,
        _ target: BuildRepairTarget
    ) {
        dismiss()
        onRequestRepair(plan, target)
    }

    private func startValidation() {
        onStart()
        session.start(onComplete: onComplete)
    }
}

private struct ValidationCheckCard: View {
    let check: ProjectValidationCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(
                    check.kind.displayName,
                    systemImage: check.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.harness(.subheadline, weight: .semibold))
                .foregroundStyle(check.succeeded ? .green : .red)
                Spacer()
                Text(String(format: "%.1f秒", check.duration))
                    .font(.harness(.caption).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("終了コード \(check.exitCode)")
                    .font(.harness(.caption2).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollView([.horizontal, .vertical]) {
                Text(check.output.isEmpty ? "出力はありません" : check.output)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottomLeading)
            .frame(minHeight: 90, maxHeight: 180)
            .padding(9)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            if check.outputWasTruncated {
                Text("長い出力の末尾40KBを表示しています。")
                    .font(.harness(.caption2))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.quaternary))
    }
}
