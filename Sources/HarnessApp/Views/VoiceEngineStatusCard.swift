import Foundation
import HarnessCore
import SwiftUI

struct VoiceEngineStatusCard: View {
    @Bindable var store: VoiceEngineStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 46, height: 46)
                    Image(systemName: statusSymbol)
                        .font(.harness(size: 20, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text("ローカル音声エンジン")
                            .font(.harness(.subheadline, weight: .semibold))
                            .accessibilityIdentifier(HarnessAccessibilityID.voiceEngineStatus)
                        Text(statusTitle)
                            .font(.harness(.caption2, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(statusColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(statusColor)
                    }
                    Text(statusDetail)
                        .font(.harness(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(store.catalogEntry.displayName) ・ \(store.catalogEntry.runtimeName)")
                        .font(.harness(.caption2))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 12)
                actionControls
            }
            if let progress = store.installationProgress {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(progress.status)
                        .font(.harness(.caption2))
                        .foregroundStyle(.secondary)
                }
            }
            if let message = store.operationMessage, !store.isInstalling {
                Label(message, systemImage: "checkmark.circle")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.harness(.caption))
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.secondary.opacity(0.065), in: RoundedRectangle(cornerRadius: 16))
        .alert("Qwen3-TTSをこのMacへ導入", isPresented: $store.pendingInstallation) {
            Button("キャンセル", role: .cancel) {}
            Button("取得を開始") { store.confirmInstallation() }
        } message: {
            Text(installationConfirmation)
        }
        .alert("音声エンジンを削除", isPresented: $store.pendingRemoval) {
            Button("キャンセル", role: .cancel) {}
            Button("完全に削除", role: .destructive) { store.confirmRemoval() }
        } message: {
            Text("専用Python、MLX-Audio、約2.52GBのモデル、途中データをこのMacから削除します。声の見本と文字起こしは残ります。この削除は取り消せません。")
        }
        .alert("途中データを破棄", isPresented: $store.pendingDiscard) {
            Button("キャンセル", role: .cancel) {}
            Button("破棄", role: .destructive) { store.confirmDiscard() }
        } message: {
            Text("取得途中のデータだけを削除します。声の見本と文字起こしは変わりません。")
        }
    }

    @ViewBuilder
    private var actionControls: some View {
        if store.isBenchmarking {
            Label("性能を測定中", systemImage: "gauge.with.dots.needle.50percent")
                .font(.harness(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
        } else if store.isInstalling {
            Button("停止", systemImage: "stop.fill") { store.stopInstallation() }
                .buttonStyle(.bordered)
                .disabled(store.installationProgress?.phase == .deleting)
                .accessibilityIdentifier(HarnessAccessibilityID.voiceEngineStop)
        } else if store.hasResumableInstallation, !store.readiness.canSynthesize {
            VStack(alignment: .trailing, spacing: 7) {
                Button("続きから再開", systemImage: "arrow.clockwise") {
                    store.resumeInstallation()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(HarnessAccessibilityID.voiceEngineResume)
                Button("途中データを破棄", role: .destructive) {
                    store.pendingDiscard = true
                }
                .buttonStyle(.plain)
                .font(.harness(.caption))
                .accessibilityIdentifier(HarnessAccessibilityID.voiceEngineDiscard)
            }
        } else if store.readiness.phase == .notInstalled {
            Button("導入する", systemImage: "arrow.down.circle") {
                store.requestInstallation()
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.preflight?.canInstall != true)
            .accessibilityIdentifier(HarnessAccessibilityID.voiceEngineInstall)
        } else {
            VStack(alignment: .trailing, spacing: 7) {
                Button("再確認", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
                .buttonStyle(.bordered)
                .disabled(store.isRefreshing)
                .accessibilityIdentifier(HarnessAccessibilityID.voiceEngineRefresh)
                Button("削除", role: .destructive) { store.pendingRemoval = true }
                    .buttonStyle(.plain)
                    .font(.harness(.caption))
                    .accessibilityIdentifier(HarnessAccessibilityID.voiceEngineRemove)
            }
        }
    }

    private var statusTitle: String {
        if store.isBenchmarking {
            return "測定中"
        }
        if store.isInstalling {
            return store.installationProgress?.phase == .deleting ? "削除中" : "準備中"
        }
        if store.hasResumableInstallation, !store.readiness.canSynthesize {
            return "停止中・再開可能"
        }
        return switch store.readiness.phase {
        case .unsupportedHardware: "このMacは対象外"
        case .notInstalled: "未導入"
        case .runtimeMissing: "実行環境が不足"
        case .modelMissing: "モデルが不足"
        case .ready: "接続準備完了"
        case .failed: "確認できません"
        }
    }

    private var statusDetail: String {
        if store.isBenchmarking {
            return "実音声を生成して、このMacでの待ち時間を測っています。削除や再確認は測定後に行えます。"
        }
        if let progress = store.installationProgress {
            return progress.status
        }
        if store.hasResumableInstallation, !store.readiness.canSynthesize {
            return "取得済みの安全な断片を残しています。「続きから再開」で同じ固定版の導入を続けられます。"
        }
        return switch store.readiness.phase {
        case .unsupportedHardware:
            "Qwen3-TTSのMac版経路はApple Silicon専用です。標準のMac音声は引き続き使えます。"
        case .notInstalled:
            preflightDetail
        case .runtimeMissing:
            "音声モデルを安全に動かす専用環境が不足しています。標準のMac音声へ自動で戻します。"
        case .modelMissing:
            "実行環境はありますが、音声モデル本体がありません。標準のMac音声へ自動で戻します。"
        case .ready:
            "端末内アダプターの診断に合格しました。実音声の品質検査後、会話の声として選べます。"
        case .failed:
            "音声エンジンの状態を確認できませんでした。標準のMac音声は引き続き使えます。"
        }
    }

    private var statusSymbol: String {
        if store.isBenchmarking { return "gauge.with.dots.needle.50percent" }
        if store.isInstalling { return "arrow.down.circle.fill" }
        return switch store.readiness.phase {
        case .ready: "checkmark.shield.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .unsupportedHardware: "cpu"
        default: "waveform.badge.magnifyingglass"
        }
    }

    private var statusColor: Color {
        if store.isBenchmarking { return .blue }
        if store.isInstalling { return .blue }
        return switch store.readiness.phase {
        case .ready: .green
        case .failed: .red
        case .unsupportedHardware: .secondary
        default: .orange
        }
    }

    private var preflightDetail: String {
        guard let preflight = store.preflight else {
            return "約2.52GBの音声モデルは未導入です。状態を確認しています。"
        }
        guard preflight.isHardwareSupported else {
            return "Qwen3-TTSのMac版経路はApple Silicon専用です。標準のMac音声は引き続き使えます。"
        }
        if let available = preflight.availableDiskBytes,
           available < preflight.requiredDiskBytes {
            return "空き容量は約\(formatted(available))です。安全な導入には6GB以上必要です。"
        }
        return "約2.52GBの音声モデルと専用環境は未導入です。導入するまで標準のMac音声を使います。"
    }

    private var installationConfirmation: String {
        let available = store.preflight?.availableDiskBytes.map(formatted) ?? "確認できません"
        return "GitHub、PyPI、Hugging Faceから固定版を取得します。モデルは約2.52GB、安全な作業用に6GB以上必要です（現在の空き: \(available)）。取得内容はSHA-256で照合し、完了まで利用状態にしません。停止後は続きから再開できます。"
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
