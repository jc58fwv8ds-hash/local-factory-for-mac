import SwiftUI

/// Settings for the light-job helper Mac (HelperNode, 2026-10-18).
struct HelperNodeSection: View {
    @AppStorage(HelperNode.Configuration.enabledKey) private var enabled = false
    @AppStorage(HelperNode.Configuration.hostKey) private var hostName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("補助の Mac").font(.harness(.headline))
            Text("Thunderbolt でつないだもう 1 台の Mac の小さなモデルに、Word・Excel・PDF の直しの指示、集計の SQL、名前の付け方の規則づくりを任せます(この Mac のモデルが回答やコードの修正で忙しいときだけ。空いているときはこの Mac のほうが速いので、この Mac で行います)。長い文章を読むときは、27B の後ろの層も補助の Mac が受け持ち、読み取りが 25〜43% 速くなります。つながっていないときや眠っているときは、この Mac だけで動きます。")
                .font(.harness(.caption)).foregroundStyle(.secondary)
            Toggle("軽い仕事を補助の Mac に任せる", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    // Turned on: load the helper's model now (no wait on the first job); turned off: stop it there.
                    Task.detached(priority: .utility) {
                        if on { _ = await HelperNode.shared.ensureReady() } else { await HelperNode.shared.stop(.init(enabled: true, hostName: HelperNode.Configuration.saved.hostName)) }
                    }
                }
            TextField("補助の Mac の名前(例: MacBook-Air)", text: $hostName)
                .textFieldStyle(.roundedBorder)
                .disabled(!enabled)
            Text("つなぎ方: 補助の Mac に専用のアカウント(lfnode)を作り、この Mac の鍵 ~/.ssh/lfnode_ed25519 を登録しておきます。補助の Mac ではモデルを自分の中だけで動かし、ネットワークには公開しません。")
                .font(.harness(.caption2)).foregroundStyle(.secondary)
        }
    }
}
