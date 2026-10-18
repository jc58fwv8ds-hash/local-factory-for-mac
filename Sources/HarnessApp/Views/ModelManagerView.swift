import HarnessCore
import SwiftUI

struct ModelManagerView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    private var manager: ModelManagerStore { store.modelManager }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    engineSection
                    acquisitionResumeSection
                    ModelOperationBanner(manager: manager)
                    recommendedSection
                    installedSection
                    PurposeModelSection()
                    HelperNodeSection()
                    customSection
                    runtimeSection
                }
                .padding(24)
            }
        }
        .frame(width: 780, height: 720)
        .onAppear {
            manager.prepare(preferredRuntime: store.project.selectedModel?.runtime)
            manager.refresh()
        }
        .alert(
            "モデルをインストール",
            isPresented: Binding(
                get: { manager.pendingInstallation != nil },
                set: { if !$0 { manager.pendingInstallation = nil } }
            )
        ) {
            Button("キャンセル", role: .cancel) {
                manager.pendingInstallation = nil
            }
            Button(installConfirmationLabel) {
                manager.confirmInstall()
            }
        } message: {
            Text(installConfirmationMessage)
        }
        .alert(
            "モデルを削除",
            isPresented: Binding(
                get: { manager.pendingRemoval != nil },
                set: { if !$0 { manager.pendingRemoval = nil } }
            )
        ) {
            Button("キャンセル", role: .cancel) {
                manager.pendingRemoval = nil
            }
            Button("削除", role: .destructive) {
                manager.confirmRemoval()
            }
        } message: {
            Text("モデル本体をディスクから削除します。プロジェクト記憶や設定は残ります。")
        }
    }

    @ViewBuilder
    private var acquisitionResumeSection: some View {
        if let checkpoint = manager.acquisitionCheckpoint,
           !manager.isInstalling {
            ModelAcquisitionResumeNotice(
                checkpoint: checkpoint,
                canResume: manager.canResumeInstallation,
                onResume: manager.resumeInstallation,
                onDiscard: manager.discardAcquisitionCheckpoint
            )
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("AIモデル")
                    .font(.harness(.title2, weight: .bold))
                    .accessibilityIdentifier(HarnessAccessibilityID.modelManager)
                Text("モデルは交換できます。プロジェクトの記憶と安全設定はLocal Factory側に残ります。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if manager.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                manager.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("一覧を更新")
            .disabled(manager.isRefreshing || manager.isInstalling)
            .accessibilityIdentifier(HarnessAccessibilityID.modelRefresh)

            Button("完了") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(HarnessAccessibilityID.modelDone)
        }
        .padding(22)
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("インストール先", systemImage: "cpu")

            if manager.installableRuntimes.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.harness(.title2))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("内蔵AIランタイムを準備中")
                            .font(.harness(.subheadline, weight: .semibold))
                        Text("現在はOllamaまたはLM Studioが必要です。将来はLocal Factoryだけでモデルを導入・実行できるようにします。")
                            .font(.harness(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                .managerCard()
            } else {
                Picker(
                    "ランタイム",
                    selection: Binding(
                        get: { manager.selectedRuntime },
                        set: { manager.selectedRuntime = $0 }
                    )
                ) {
                    ForEach(manager.installableRuntimes) { runtime in
                        Text(runtime.rawValue).tag(runtime)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(HarnessAccessibilityID.modelRuntime)
            }
        }
    }

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("このMacにおすすめ", systemImage: "sparkles")
                Spacer()
                Text(manager.hostResourceSummary)
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(HarnessAccessibilityID.modelResources)

            HStack(alignment: .top, spacing: 12) {
                ForEach(manager.catalog) { entry in
                    let assessment = manager.fitAssessment(for: entry)
                    CatalogCard(
                        entry: entry,
                        assessment: assessment,
                        isInstalled: isInstalled(entry),
                        isBusy: manager.blocksNewInstallation || !assessment.canInstall,
                        install: { manager.requestInstall(entry) }
                    )
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("インストール済み", systemImage: "internaldrive")
                Spacer()
                if !manager.inventory.models.isEmpty {
                    Text("\(manager.inventory.models.count)モデル")
                        .font(.harness(.caption))
                        .foregroundStyle(.secondary)
                }
            }

            if manager.isRefreshing && manager.inventory.models.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("モデルを確認しています…")
                        .font(.harness(.caption))
                        .foregroundStyle(.secondary)
                }
                .managerCard()
            } else if manager.inventory.models.isEmpty {
                Text("まだモデルはありません。上の候補から選ぶと、Local Factoryがダウンロードと設定を行います。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                    .managerCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(manager.inventory.models.enumerated()), id: \.element.id) { index, model in
                        InstalledModelRow(
                            model: model,
                            isSelected: store.project.selectedModel?.identifier == model.identifier,
                            select: { store.selectModel(model) },
                            remove: { manager.requestRemoval(model) }
                        )
                        if index < manager.inventory.models.count - 1 {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
            }
        }
    }

    private var customSection: some View {
        DisclosureGroup("モデルIDを指定") {
            HStack(spacing: 10) {
                TextField(
                    manager.selectedRuntime == .ollama
                        ? "例: hf.co/lmstudio-community/Qwen3.8-27B-GGUF:Q4_K_M"
                        : "モデルIDまたはHugging Face URL",
                    text: Binding(
                        get: { manager.customIdentifier },
                        set: { manager.customIdentifier = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)

                Button("インストール") {
                    manager.requestCustomInstall()
                }
                .disabled(manager.blocksNewInstallation || !manager.hasInstallableRuntime)
            }
            .padding(.top, 10)
        }
        .font(.harness(.subheadline, weight: .medium))
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("AIエンジン", systemImage: "gearshape.2")

            ForEach(manager.inventory.runtimes) { report in
                HStack(spacing: 12) {
                    Circle()
                        .fill(runtimeColor(report.availability))
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.runtime.kind.rawValue)
                            .font(.harness(.caption, weight: .semibold))
                        Text(report.detail)
                            .font(.harness(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if report.runtime.isInstalled,
                       report.availability != .ready,
                       report.runtime.kind != .harness {
                        Button("起動") {
                            manager.openRuntime(report.runtime.kind)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var installConfirmationLabel: String {
        guard let entry = manager.pendingInstallation else { return "ダウンロード" }
        return entry.estimatedSizeGB > 0
            ? "約\(entry.estimatedSizeGB.formatted())GBをダウンロード"
            : "ダウンロード"
    }

    private var installConfirmationMessage: String {
        guard let entry = manager.pendingInstallation else { return "" }
        let sizeMessage = entry.estimatedSizeGB > 0
            ? "約\(entry.estimatedSizeGB.formatted())GBをダウンロードします。"
            : "モデルをダウンロードします。"
        let advice = manager.installationAdvice(for: entry)
        return "\(entry.displayName)を\(manager.selectedRuntime.rawValue)へインストールします。\(sizeMessage)\(advice)完了するまでMacをスリープさせないでください。"
    }

    private func isInstalled(_ entry: ModelCatalogEntry) -> Bool {
        guard !entry.matchingTokens.isEmpty else { return false }
        return manager.inventory.models.contains { model in
            let normalized = model.identifier.lowercased()
            return entry.matchingTokens.allSatisfy { normalized.contains($0.lowercased()) }
        }
    }

    private func runtimeColor(_ availability: RuntimeAvailability) -> Color {
        switch availability {
        case .ready: .green
        case .installedButStopped, .timedOut: .orange
        case .notInstalled: .secondary.opacity(0.45)
        case .failed: .red
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.harness(.headline))
    }
}
