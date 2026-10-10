import SwiftUI

struct RemoteControlCard: View {
    @Bindable var remote: RemoteControlStore
    let selectedProjectName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("iPhoneリモート", systemImage: "iphone.radiowaves.left.and.right")
                    .font(.harness(.subheadline, weight: .semibold))
                Spacer()
                Label(statusTitle, systemImage: statusSymbol)
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            Toggle(
                "リモート指示を許可",
                isOn: Binding(
                    get: { remote.isEnabled },
                    set: { remote.setEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier(HarnessAccessibilityID.remoteControlToggle)

            if remote.isEnabled {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ペアリングコード")
                        .font(.harness(.caption))
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(remote.pairingCode)
                            .font(.harness(size: 22, weight: .semibold))
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .accessibilityIdentifier(HarnessAccessibilityID.remotePairingCode)
                        Spacer()
                        Button("更新") { remote.rotatePairingCode() }
                            .controlSize(.small)
                    }
                }

                Text(remote.statusMessage)
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("暗号化した近距離接続で、現在選択中の「\(selectedProjectName ?? "プロジェクトなし")」だけへ指示します。コードと接続状態は保存しません。")
                    .font(.harness(.caption2))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("必要なときだけ有効にし、iPhoneへ表示中の6桁コードを入力します。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .inspectorCard()
    }

    private var statusTitle: String {
        if remote.connectedPeerName != nil { return "接続済み" }
        return remote.isEnabled ? "待機中" : "停止"
    }

    private var statusSymbol: String {
        if remote.connectedPeerName != nil { return "checkmark.circle.fill" }
        return remote.isEnabled ? "antenna.radiowaves.left.and.right" : "pause.circle"
    }

    private var statusColor: Color {
        if remote.connectedPeerName != nil { return .green }
        return remote.isEnabled ? .orange : .secondary
    }
}
