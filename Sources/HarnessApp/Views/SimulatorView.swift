import AppKit
import HarnessCore
import SwiftUI

struct SimulatorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: SimulatorSession

    init(provider: any SimulatorProviding) {
        _session = State(initialValue: SimulatorSession(provider: provider))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    safetyNotice
                    content
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 620)
        .task {
            if session.devices.isEmpty && !session.isBusy {
                session.refresh()
            }
        }
        .onDisappear { session.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.gen3")
                .font(.harness(.title2))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Simulator確認")
                    .font(.harness(.headline))
                Text("起動状態を確認し、画面を一時的に取得します。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("完了") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("固定されたSimulator操作", systemImage: "lock.shield")
                .font(.harness(.subheadline, weight: .semibold))
            Text("simctl list  →  必要時のみ boot  →  io screenshot")
                .font(.harness(.caption).monospaced())
            Text("端末の作成・削除・初期化・終了は行いません。画像はメモリ上だけで表示します。")
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
            progressContent("利用可能なSimulatorを確認しています…")
        } else if session.devices.isEmpty {
            ContentUnavailableView(
                "利用可能なSimulatorがありません",
                systemImage: "iphone.slash",
                description: Text("XcodeのSettings > ComponentsまたはDevice Hubを確認してください。")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 70)
        } else {
            deviceWorkspace
        }

        if let errorMessage = session.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.harness(.caption))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let statusMessage = session.statusMessage {
            Label(statusMessage, systemImage: "checkmark.circle.fill")
                .font(.harness(.caption))
                .foregroundStyle(.green)
        }
    }

    private var deviceWorkspace: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("端末")
                    .font(.harness(.subheadline, weight: .semibold))
                ForEach(session.devices) { device in
                    SimulatorDeviceRow(
                        device: device,
                        isSelected: device.id == session.selectedDeviceID
                    ) {
                        session.selectDevice(device.id)
                    }
                }
            }
            .frame(width: 260)

            screenshotPreview
                .frame(maxWidth: .infinity, minHeight: 360)
        }
    }

    @ViewBuilder
    private var screenshotPreview: some View {
        if session.phase == .booting {
            progressContent("Simulatorを起動しています…")
        } else if session.phase == .capturing {
            progressContent("スクリーンショットを取得しています…")
        } else if let screenshot = session.screenshot,
                  let image = NSImage(data: screenshot.pngData) {
            VStack(spacing: 9) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                Text("\(screenshot.device.name)・\(screenshot.capturedAt, style: .time)")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView(
                "画面はまだ取得していません",
                systemImage: "camera.viewfinder",
                description: Text("起動中の端末を選び、スクリーンショットを取得してください。")
            )
        }
    }

    private func progressContent(_ title: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(title)
                .font(.harness(.headline))
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var footer: some View {
        HStack {
            Text("利用可能: \(session.devices.count)台")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
            Spacer()
            Button("一覧を更新") { session.refresh() }
                .disabled(session.isBusy)
            if let device = session.selectedDevice {
                if device.state == .booted {
                    Button("スクリーンショットを取得") { session.captureSelected() }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isBusy)
                } else {
                    Button("この端末を起動") { session.bootSelected() }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isBusy || device.state == .other)
                }
            }
        }
        .padding(16)
    }
}

private struct SimulatorDeviceRow: View {
    let device: SimulatorDevice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: device.state == .booted ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3")
                    .foregroundStyle(device.state == .booted ? .green : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.harness(.caption, weight: .semibold))
                    Text("\(device.runtimeName)・\(device.state.displayName)")
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
