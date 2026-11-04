import SwiftUI

/// The remote part of the agent screen (2026-11-02): pairing an iPhone with 6 digits, the paired devices, and the
/// addresses to use at home and away (Tailscale).
struct AgentRemoteCard: View {
    @Bindable var link: AgentRemoteLink
    @State private var addresses: [AgentRemoteLink.Address] = []
    var onInstallApp: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("iPhone から頼めるようにする", isOn: Binding(get: { link.isEnabled }, set: { link.setEnabled($0) }))
                .toggleStyle(.switch)
            Button("iPhone にアプリ(Local Factory Remote)を入れる…") { onInstallApp() }
                .buttonStyle(.link)
                .help("「アプリ」欄に移ります。iPhone を USB か同じ Wi-Fi でつなぎ、「Local Factory Remote(iPhone)」を選んで入れてください")
            Text("中継サーバーは使わず、つないだ iPhone とだけ直接、暗号化してやり取りします。家の外からは Tailscale を通ります。")
                .font(.harness(.caption)).foregroundStyle(.secondary)
            if link.isEnabled {
                if let pending = link.pendingPairing {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("「\(pending.deviceName)」をつなぎますか").font(.harness(.subheadline, weight: .semibold))
                        Text(pending.code).font(.system(size: 34, weight: .bold, design: .monospaced))
                        Text("iPhone に同じ 6 桁が出ているときだけ「つなぐ」を押してください。").font(.harness(.caption)).foregroundStyle(.secondary)
                        HStack {
                            Button("つなぐ") { link.decidePairing(true) }.buttonStyle(.borderedProminent)
                            Button("断る") { link.decidePairing(false) }
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                } else if link.pairingOpenUntil != nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("iPhone からの接続を待っています").font(.harness(.caption))
                        Button("やめる") { link.closePairing() }
                    }
                } else {
                    Button("iPhone をつなぐ…") { link.openPairing() }
                }
                ForEach(link.devices) { device in
                    HStack {
                        Label(device.name, systemImage: "iphone").font(.harness(.caption))
                        Spacer()
                        Button("外す") { link.remove(device) }.buttonStyle(.borderless)
                    }
                }
                ForEach(addresses) { address in
                    Text("\(address.isTailscale ? "外から(Tailscale)" : "家の中"): \(address.ip)")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if !addresses.contains(where: \.isTailscale) {
                    Text("家の外から使うには、Mac と iPhone の両方で Tailscale に接続してください。")
                        .font(.harness(.caption)).foregroundStyle(.secondary)
                }
                if !link.message.isEmpty { Text(link.message).font(.harness(.caption)) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { addresses = AgentRemoteLink.addresses() }
        .onChange(of: link.isEnabled) { addresses = AgentRemoteLink.addresses() }
    }
}
