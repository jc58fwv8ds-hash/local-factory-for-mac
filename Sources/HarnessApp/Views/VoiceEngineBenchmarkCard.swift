import HarnessCore
import SwiftUI

struct VoiceEngineBenchmarkCard: View {
    @Bindable var engineStore: VoiceEngineStore
    let capsules: [VoiceCapsuleManifest]

    @State private var selectedCapsuleID: UUID?

    private var session: VoiceEngineBenchmarkSession {
        engineStore.benchmarkSession
    }

    private var eligibleCapsules: [VoiceCapsuleManifest] {
        capsules.filter { $0.references.first?.transcriptContentHash != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.harness(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("実音声チェック")
                        .font(.harness(.headline, weight: .semibold))
                    Text("同じ短文を2回生成し、待ち時間と実時間比をこのMac上で測ります")
                        .font(.harness(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                controls
            }

            capsuleSelection
            runningStatus
            if let report = session.report {
                reportView(report)
            }
            if let message = session.cancellationMessage {
                Label(message, systemImage: "stop.circle")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.harness(.caption))
                    .foregroundStyle(.red)
            }
            Text("測定用の文章と生成音声は保存しません。実時間比は1未満ほど高速です。")
                .font(.harness(.caption2))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .onAppear { resolveSelection() }
        .onChange(of: eligibleCapsules.map(\.id)) { _, _ in resolveSelection() }
        .onDisappear { engineStore.stopBenchmark() }
    }

    @ViewBuilder
    private var controls: some View {
        if engineStore.isBenchmarking {
            Button("中止", systemImage: "stop.fill") { engineStore.stopBenchmark() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(HarnessAccessibilityID.voiceEngineBenchmarkStop)
        } else {
            Button("性能を測る", systemImage: "gauge.with.dots.needle.67percent") {
                guard let selectedCapsuleID else { return }
                engineStore.startBenchmark(capsuleID: selectedCapsuleID)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                !engineStore.readiness.canSynthesize
                    || engineStore.isRefreshing
                    || engineStore.isInstalling
                    || selectedCapsuleID == nil
            )
            .accessibilityIdentifier(HarnessAccessibilityID.voiceEngineBenchmarkRun)
        }
    }

    @ViewBuilder
    private var capsuleSelection: some View {
        if eligibleCapsules.count > 1 {
            Picker("テストする声", selection: $selectedCapsuleID) {
                ForEach(eligibleCapsules) { capsule in
                    Text(capsule.displayName).tag(Optional(capsule.id))
                }
            }
            .pickerStyle(.menu)
        } else if let capsule = eligibleCapsules.first {
            Label("テストする声：\(capsule.displayName)", systemImage: "waveform")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
        } else {
            Label("文字起こし付きの声モデルを先に用意してください", systemImage: "waveform.badge.plus")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var runningStatus: some View {
        if engineStore.isBenchmarking {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(
                    value: Double(session.currentStep - 1),
                    total: Double(VoiceEngineBenchmarkPolicy.requiredMeasurementCount)
                )
                Text("\(session.currentStep)回目を生成しています。初回はモデル準備を含むため長くなることがあります。")
                    .font(.harness(.caption2))
                    .foregroundStyle(.secondary)
            }
        } else if !engineStore.readiness.canSynthesize {
            Text("ローカル音声エンジンの導入と診断が終わると測定できます。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
        }
    }

    private func reportView(_ report: VoiceEngineBenchmarkReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(assessmentTitle(report.assessment), systemImage: assessmentSymbol(report.assessment))
                .font(.harness(.subheadline, weight: .semibold))
                .foregroundStyle(assessmentColor(report.assessment))
            HStack(spacing: 12) {
                metric("初回", measurement: report.initialMeasurement)
                metric("再測定", measurement: report.repeatedMeasurement)
            }
            Text(assessmentDetail(report.assessment))
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(assessmentColor(report.assessment).opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metric(
        _ title: String,
        measurement: VoiceEngineBenchmarkMeasurement?
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.harness(.caption2, weight: .semibold))
            Text(measurement.map {
                String(format: "%.2f秒・実時間比 %.2f", Double($0.elapsedMilliseconds) / 1_000, $0.realTimeFactor)
            } ?? "—")
            .font(.harness(.caption))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func assessmentTitle(_ assessment: VoiceEngineBenchmarkAssessment) -> String {
        switch assessment {
        case .conversationCandidate: "会話への接続候補"
        case .usableWithPause: "少し間を置けば利用可能"
        case .previewOnly: "現在は試聴向け"
        }
    }

    private func assessmentDetail(_ assessment: VoiceEngineBenchmarkAssessment) -> String {
        switch assessment {
        case .conversationCandidate:
            "速度の一次基準を通過しました。次は実際に聞いて、日本語の自然さと声の近さを確認します。"
        case .usableWithPause:
            "音声は生成できますが、会話では待ち時間を感じる可能性があります。標準音声への自動切替を維持します。"
        case .previewOnly:
            "今の非ストリーミング経路では会話の間が長くなります。モデル常駐化かストリーミング化が必要です。"
        }
    }

    private func assessmentSymbol(_ assessment: VoiceEngineBenchmarkAssessment) -> String {
        switch assessment {
        case .conversationCandidate: "checkmark.circle.fill"
        case .usableWithPause: "clock.badge.checkmark"
        case .previewOnly: "exclamationmark.triangle.fill"
        }
    }

    private func assessmentColor(_ assessment: VoiceEngineBenchmarkAssessment) -> Color {
        switch assessment {
        case .conversationCandidate: .green
        case .usableWithPause: .orange
        case .previewOnly: .red
        }
    }

    private func resolveSelection() {
        if let selectedCapsuleID,
           eligibleCapsules.contains(where: { $0.id == selectedCapsuleID }) {
            return
        }
        selectedCapsuleID = eligibleCapsules.first?.id
    }
}
