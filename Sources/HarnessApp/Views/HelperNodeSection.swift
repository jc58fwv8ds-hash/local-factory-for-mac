import SwiftUI

/// Settings for the light-job helper Mac (HelperNode, 2026-10-18).
struct HelperNodeSection: View {
    @AppStorage(HelperNode.Configuration.enabledKey) private var enabled = false
    @AppStorage(HelperNode.Configuration.hostKey) private var hostName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("補助の Mac").font(.harness(.headline))
            Text("Thunderbolt でつないだもう 1 台の Mac の小さなモデルに、Word・Excel・PDF の直しの指示、集計の SQL、名前の付け方の規則づくりを任せます。この Mac のモデルはコードの修正に使えます。つながっていないときや眠っているときは、この Mac で動きます。")
                .font(.harness(.caption)).foregroundStyle(.secondary)
            Toggle("軽い仕事を補助の Mac に任せる", isOn: $enabled)
            TextField("補助の Mac の名前(例: MacBook-Air)", text: $hostName)
                .textFieldStyle(.roundedBorder)
                .disabled(!enabled)
            Text("つなぎ方: 補助の Mac に専用のアカウント(lfnode)を作り、この Mac の鍵 ~/.ssh/lfnode_ed25519 を登録しておきます。補助の Mac ではモデルを自分の中だけで動かし、ネットワークには公開しません。")
                .font(.harness(.caption2)).foregroundStyle(.secondary)
        }
    }
}
