import AppKit
import HarnessCore
import SwiftUI

struct AppleAppInstallPanel: View {
    @Bindable var session: AppleAppLibrarySession
    let onOpenXcode: () -> Void
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let app = session.selectedApp {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        appSummary(app)
                        targetSection(app)
                        if needsSigningSetup(app) {
                            signingSetup
                        }
                        activity
                    }
                    .padding(22)
                }
                Divider()
                footer(app)
            } else {
                ContentUnavailableView(
                    "アプリを選択",
                    systemImage: "hand.tap",
                    description: Text("左のタイルからインストールするアプリを選びます。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            }
        }
        .background(.ultraThinMaterial)
    }

    private func appSummary(_ app: InstallableAppleApp) -> some View {
        HStack(spacing: 13) {
            compactIcon(app)
            VStack(alignment: .leading, spacing: 3) {
                Text("インストール先")
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(app.displayName)
                    .font(.harness(.title2, weight: .bold))
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func compactIcon(_ app: InstallableAppleApp) -> some View {
        if let data = app.iconData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .frame(width: 54, height: 54)
        } else {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.accentColor.gradient)
                .overlay {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.harness(.title3))
                        .foregroundStyle(.white)
                }
                .frame(width: 54, height: 54)
        }
    }

    private func targetSection(_ app: InstallableAppleApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("端末を選択")
                .font(.harness(.headline))
            Text("必要な端末だけを選んでください。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)

            ForEach(AppleAppPlatform.allCases, id: \.self) { platform in
                InstallTargetRow(
                    platform: platform,
                    configuration: app.configuration(for: platform),
                    devices: session.devices(for: platform),
                    selectedDevice: session.selectedDevice(for: platform),
                    isSelected: session.selectedPlatforms.contains(platform),
                    isBusy: session.isBusy,
                    onToggle: { session.toggle(platform) },
                    onSelectDevice: { session.selectDevice($0, for: platform) }
                )
            }

            if session.selectedPlatforms.contains(.appleWatch),
               app.configuration(for: .appleWatch)?.watchRelationship == .requiresCompanion,
               app.configuration(for: .iPhone) != nil {
                Label("このWatchアプリはiPhone版を先に自動インストールします。", systemImage: "link")
                    .font(.harness(.caption2))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var signingSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("最初の1回だけ", systemImage: "person.badge.key.fill")
                .font(.harness(.subheadline, weight: .semibold))
                .foregroundStyle(.orange)
            Text("XcodeでApple AccountのPersonal Teamを選ぶと、無料で実機へ入れられます。パスワードはLocal Factoryへ渡りません。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
            Button("Xcodeで無料署名を設定", action: onOpenXcode)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(.orange.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var activity: some View {
        if session.phase == .installing, let platform = session.activePlatform {
            VStack(alignment: .leading, spacing: 9) {
                ProgressView()
                Text(session.installStage?.displayName(for: platform) ?? "準備しています…")
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
        } else if !session.reports.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(session.reports, id: \.platform) { report in
                    Label(
                        "\(report.platform.displayName)へインストール済み",
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(.green)
                }
            }
        }
    }

    private func footer(_ app: InstallableAppleApp) -> some View {
        VStack(spacing: 10) {
            Button(action: onInstall) {
                Label(installButtonTitle, systemImage: "arrow.down.app.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!session.canInstall)
            .accessibilityIdentifier(HarnessAccessibilityID.appLibraryInstall)

            Text(footerGuidance(app))
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(18)
    }

    private func needsSigningSetup(_ app: InstallableAppleApp) -> Bool {
        session.installationOrder.contains { platform in
            guard let configuration = app.configuration(for: platform) else { return false }
            return configuration.signingStyle != .automatic
                || !configuration.hasDevelopmentTeam
                || !configuration.hasUsableBundleIdentifier
        }
    }

    private var installButtonTitle: String {
        if session.phase == .installing { return "インストール中…" }
        let count = session.installationOrder.count
        return count > 1 ? "2台へインストール" : "インストール"
    }

    private func footerGuidance(_ app: InstallableAppleApp) -> String {
        if session.installationOrder.isEmpty { return "インストールする端末を選択してください" }
        if needsSigningSetup(app) { return "無料署名の設定後にインストールできます" }
        let missing = session.installationOrder.filter { session.selectedDevice(for: $0) == nil }
        if !missing.isEmpty {
            return "\(missing.map(\.displayName).joined(separator: "と"))を接続して一覧を更新してください"
        }
        return "署名・ビルド・転送・起動はLocal Factoryが背後で行います"
    }
}

private struct InstallTargetRow: View {
    let platform: AppleAppPlatform
    let configuration: AppleAppBuildConfiguration?
    let devices: [PhysicalAppleDevice]
    let selectedDevice: PhysicalAppleDevice?
    let isSelected: Bool
    let isBusy: Bool
    let onToggle: () -> Void
    let onSelectDevice: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 11) {
                    Image(systemName: platform == .iPhone ? "iphone.gen3" : "applewatch")
                        .font(.harness(.title3))
                        .foregroundStyle(configuration == nil ? .secondary : Color.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(platform.displayName)
                            .font(.harness(.subheadline, weight: .semibold))
                        Text(statusText)
                            .font(.harness(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(configuration == nil || isBusy)

            if isSelected, devices.count > 1 {
                Picker("端末", selection: selectedDeviceBinding) {
                    ForEach(devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            Color.accentColor.opacity(isSelected ? 0.08 : 0.025),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.32) : Color.secondary.opacity(0.16)
                )
        }
        .opacity(configuration == nil ? 0.58 : 1)
    }

    private var statusText: String {
        guard let configuration else { return "このアプリは対応していません" }
        guard let selectedDevice else { return "端末が接続されていません" }
        if configuration.signingStyle != .automatic || !configuration.hasDevelopmentTeam {
            return "無料署名の設定が必要です"
        }
        return "\(selectedDevice.name)・接続済み"
    }

    private var selectedDeviceBinding: Binding<String> {
        Binding(
            get: { selectedDevice?.id ?? devices.first?.id ?? "" },
            set: { value in onSelectDevice(value) }
        )
    }
}
