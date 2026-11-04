import SwiftUI

/// The agent tab (2026-11-02): pair with the Mac once, then ask it to do things on the Mac and answer its approvals.
@MainActor
struct AgentScreen: View {
    @State private var client = AgentClient()
    @State private var host = ""
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            Group {
                if client.saved == nil { pairing } else { conversation }
            }
            .navigationTitle("エージェント")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if client.saved != nil {
                    Menu {
                        Button("つなぎ直す") { client.connect() }
                        Button("この Mac を忘れる", role: .destructive) { client.forget() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .onAppear { if client.saved != nil, !client.isConnected { client.connect() } }
        // iOS cuts the link while the app is in the background: open it again on return (2026-11-04).
        .onChange(of: scenePhase) { if scenePhase == .active { client.resume() } }
    }

    private var pairing: some View {
        Form {
            Section {
                Text("Mac の Local Factory で「エージェント」→ 右上の「iPhone とつなぐ」→「iPhone をつなぐ…」を押してください。同じ Wi-Fi にいる Mac が下に出ます。")
                    .font(.callout)
                Button("Mac を探す") { client.browseForPairing() }
                ForEach(client.pairingMacs, id: \.self) { name in
                    Button(name) { client.pair(with: name) }
                }
            }
            Section("家の外から(Tailscale の住所)") {
                TextField("100.x.y.z", text: $host).keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
                Button("この住所の Mac とつなぐ") { client.pair(host: host) }
            }
            if let code = client.pairingCode {
                Section("Mac に同じ数字が出ているか確かめてください") {
                    Text(code).font(.system(size: 40, weight: .bold, design: .monospaced))
                    Text("同じなら Mac で「つなぐ」を押します。違うときは押さないでください。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section { Text(client.status).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: client.isConnected ? "lock.shield.fill" : "exclamationmark.triangle")
                Text(client.status).font(.footnote)
                Spacer()
            }
            .foregroundStyle(client.isConnected ? .green : .orange)
            .padding(.horizontal).padding(.vertical, 6)
            if !client.notice.isEmpty {
                Text(client.notice).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }
            ScrollViewReader { proxy in
                List(client.entries) { entry in
                    row(entry).id(entry.id)
                }
                .listStyle(.plain)
                // The keyboard closes by dragging the list down or tapping it (2026-11-04, the user could not cancel input).
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture { typing = false }
                .onChange(of: client.entries.count) {
                    if let last = client.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if client.running, let end = client.expectedEnd {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = Int(end.timeIntervalSince(context.date).rounded(.up))
                    Text(left > 0 ? "Mac で実行中: 残り およそ \(left >= 60 ? "\(left / 60 + 1) 分" : "\(left) 秒")" : "Mac で実行中: 目安の時間を過ぎています")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }
            if client.approvalID != nil, let approval = client.entries.last(where: { $0.kind == .approval }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("この操作をしてよいですか").font(.headline)
                    Text(approval.text)
                    Text(approval.detail).font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button("する") { client.approve(true) }.buttonStyle(.borderedProminent)
                        Button("しない(止める)") { client.approve(false) }.buttonStyle(.bordered)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15))
            }
            HStack(alignment: .bottom) {
                TextField("Mac でしてほしいこと", text: $client.draft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                    .focused($typing)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("閉じる") { typing = false }
                        }
                    }
                if client.running {
                    Button("止める") { client.interrupt() }.buttonStyle(.bordered)
                } else {
                    Button("送る") { client.sendDraft(); typing = false }.buttonStyle(.borderedProminent)
                        .disabled(client.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            DisclosureGroup("家の外から使う") {
                TextField("Mac の Tailscale の住所(100.x.y.z)", text: Binding(get: { client.saved?.awayHost ?? "" }, set: { client.setAwayHost($0) }))
                    .keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
            }
            .font(.footnote).padding(.horizontal).padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func row(_ entry: AgentEntry) -> some View {
        switch entry.kind {
        case .request:
            HStack { Spacer(minLength: 40); Text(entry.text).padding(10).background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12)) }
                .listRowSeparator(.hidden)
        case .step:
            Text("\(entry.text) → \(entry.detail)").font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
        case .approval:
            Label("確認: \(entry.text)", systemImage: "exclamationmark.shield").font(.footnote).foregroundStyle(.orange).listRowSeparator(.hidden)
        case .question, .outcome:
            Text(entry.text).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12)).listRowSeparator(.hidden)
        }
    }
}
