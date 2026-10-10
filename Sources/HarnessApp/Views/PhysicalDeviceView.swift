import HarnessCore
import SwiftUI

struct PhysicalDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: PhysicalDeviceSession
    @State private var isConfirmingRun = false
    private let rootPath: String
    private let opener: any XcodeProjectOpening

    init(
        rootPath: String,
        provider: any PhysicalDeviceProviding,
        opener: any XcodeProjectOpening
    ) {
        self.rootPath = rootPath
        self.opener = opener
        _session = State(
            initialValue: PhysicalDeviceSession(rootPath: rootPath, provider: provider)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    freeTeamNotice
                    content
                    feedback
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 800, minHeight: 650)
        .task {
            if session.devices.isEmpty && !session.isBusy {
                session.refresh()
            }
        }
        .onDisappear { session.stop() }
        .confirmationDialog(
            "無料の開発用署名でiPhoneへ実行しますか？",
            isPresented: $isConfirmingRun,
            titleVisibility: .visible
        ) {
            Button("署名・インストール・起動を実行") {
                session.runSelected()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("XcodeがPersonal Team用の証明書・App ID・プロファイルを作成または更新する場合があります。公開や課金は行いません。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.harness(.title2))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("実機iPhoneで確認")
                    .font(.harness(.headline))
                Text("接続、無料署名、インストール、起動を一続きで確認します。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("完了") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var freeTeamNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Apple Personal Team（無料）", systemImage: "person.badge.key.fill")
                .font(.harness(.subheadline, weight: .semibold))
            Text("Apple Accountのパスワード入力、「このコンピュータを信頼」、Developer Modeの確認は本人が行います。Local Factoryは認証情報を取得・保存しません。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
            Text("無料プロファイルは通常7日ごとに再署名が必要です。App Store公開や有料登録は行いません。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var content: some View {
        if session.phase == .loading && session.devices.isEmpty {
            progressContent("接続中のiPhoneと署名設定を確認しています…")
        } else if session.devices.isEmpty {
            ContentUnavailableView(
                "接続中のiPhoneがありません",
                systemImage: "cable.connector.slash",
                description: Text("iPhoneをUSBで接続し、ロック解除後に「信頼」を許可して一覧を更新してください。")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 70)
        } else {
            deviceWorkspace
        }
    }

    private var deviceWorkspace: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("接続端末")
                    .font(.harness(.subheadline, weight: .semibold))
                ForEach(session.devices) { device in
                    PhysicalDeviceRow(
                        device: device,
                        isSelected: device.id == session.selectedDeviceID
                    ) {
                        session.selectDevice(device.id)
                    }
                }
            }
            .frame(width: 260)

            readinessPanel
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var readinessPanel: some View {
        if session.phase == .inspecting || session.readiness == nil {
            progressContent("実行条件を確認しています…")
        } else if let readiness = session.readiness {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("実行準備")
                        .font(.harness(.headline))
                    Spacer()
                    Text(readiness.canRun ? "準備完了" : "設定が必要")
                        .font(.harness(.caption, weight: .semibold))
                        .foregroundStyle(readiness.canRun ? .green : .orange)
                }

                ForEach(DevicePreparationCheck.allCases, id: \.self) { check in
                    let current = readiness.preparation.map { $0.isCurrent(for: $0.deviceIdentifier) } == true
                    DeviceReadinessRow(
                        title: check.title,
                        detail: current ? readiness.preparation?.state(for: check).displayName ?? "未確認" : "再確認が必要",
                        isReady: current && readiness.preparation?.state(for: check) == .met
                    )
                }
                Text(readiness.preparation?.summary() ?? "端末の接続・開発準備状態は未確認です。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                DeviceReadinessRow(
                    title: "iOSアプリ",
                    detail: "\(readiness.project.containerName) / \(readiness.project.scheme)",
                    isReady: readiness.project.isIOSApplication
                )
                DeviceReadinessRow(
                    title: "Automatic Signing",
                    detail: signingDetail(readiness.project.signingStyle),
                    isReady: readiness.project.signingStyle == .automatic
                )
                DeviceReadinessRow(
                    title: "Personal Team",
                    detail: readiness.project.hasDevelopmentTeam ? "選択済み" : "Xcodeで選択が必要",
                    isReady: readiness.project.hasDevelopmentTeam
                )
                DeviceReadinessRow(
                    title: "Bundle Identifier",
                    detail: readiness.project.bundleIdentifier ?? "未設定",
                    isReady: readiness.project.hasUsableBundleIdentifier
                )

                if readiness.requirements.contains(where: { $0 != .verifyDeviceState }) {
                    setupGuide(requirements: readiness.requirements)
                }
            }
        }
    }

    private func setupGuide(
        requirements: [PhysicalDeviceSetupRequirement]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("無料署名の初回設定")
                .font(.harness(.subheadline, weight: .semibold))
            Text("1. Xcode > Settings > AccountsでApple Accountを追加")
            Text("2. アプリTarget > Signing & CapabilitiesでAutomatically manage signingを有効化")
            Text("3. Teamに自分のPersonal Teamを選択し、警告が消えたら再確認")
            if !requirements.isEmpty {
                Text("現在必要: \(requirements.map(\.title).joined(separator: "・"))")
                    .foregroundStyle(.orange)
            }
            Button("Xcodeでプロジェクトを開く", action: openXcode)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier(HarnessAccessibilityID.physicalDeviceOpenXcode)
        }
        .font(.harness(.caption))
        .padding(11)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private var feedback: some View {
        if session.phase == .running {
            Label(
                session.runStage?.displayName ?? "実機での実行を準備しています…",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.harness(.caption, weight: .medium))
            .foregroundStyle(Color.accentColor)
        } else if let error = session.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.harness(.caption))
                .foregroundStyle(.red)
        } else if let report = session.runReport {
            Label(
                "\(report.productName)を\(report.deviceName)で起動しました",
                systemImage: "checkmark.seal.fill"
            )
            .font(.harness(.caption, weight: .semibold))
            .foregroundStyle(.green)
        } else if let status = session.statusMessage {
            Label(status, systemImage: "checkmark.circle.fill")
                .font(.harness(.caption))
                .foregroundStyle(.green)
        }
    }

    private var footer: some View {
        HStack {
            Text("端末ID・Team ID・ビルドログは保存しません")
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)
            Spacer()
            Button("一覧と署名を再確認") { session.refresh() }
                .disabled(session.isBusy)
                .accessibilityIdentifier(HarnessAccessibilityID.physicalDeviceRefresh)
            Button("無料署名でiPhoneへ実行") { isConfirmingRun = true }
                .buttonStyle(.borderedProminent)
                .disabled(session.isBusy || session.readiness?.canRun != true)
                .accessibilityIdentifier(HarnessAccessibilityID.physicalDeviceRun)
        }
        .padding(16)
    }

    private func openXcode() {
        do {
            try opener.openXcodeProject(rootPath: rootPath)
        } catch {
            session.present(error: error)
        }
    }

    private func signingDetail(_ style: XcodeSigningStyle) -> String {
        switch style {
        case .automatic: "有効"
        case .manual: "ManualからAutomaticへ変更が必要"
        case .unknown: "設定を確認できません"
        }
    }

    private func progressContent(_ title: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(title).font(.harness(.headline))
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

private struct PhysicalDeviceRow: View {
    let device: PhysicalAppleDevice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: device.connection == .wired ? "cable.connector" : "iphone.gen3")
                    .foregroundStyle(device.isPaired ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.harness(.caption, weight: .semibold))
                    Text("\(device.modelName)・iOS \(device.osVersion)")
                        .font(.harness(.caption2))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(9)
            .background(
                Color.accentColor.opacity(isSelected ? 0.1 : 0.025),
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct DeviceReadinessRow: View {
    let title: String
    let detail: String
    let isReady: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.harness(.caption, weight: .semibold))
                Text(detail)
                    .font(.harness(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
