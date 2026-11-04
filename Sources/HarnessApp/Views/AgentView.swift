import HarnessCore
import SwiftUI

/// The agent screen (2026-11-02): a conversation in which the user asks for things to be done on this Mac (apps, Safari,
/// web search); the agent's actions, its questions and the approvals it waits for appear in the same list.
struct AgentView: View {
    @Bindable var agent: AgentStore
    @Bindable var link: AgentRemoteLink = .shared
    @State private var showsRemote = false
    var onInstallRemoteApp: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            if showsRemote { AgentRemoteCard(link: link, onInstallApp: onInstallRemoteApp).padding(.horizontal, 20).padding(.bottom, 12) }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if agent.entries.isEmpty { emptyState }
                        ForEach(agent.entries) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 820, alignment: .leading)
                }
                .onChange(of: agent.entries.count) {
                    if let last = agent.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if agent.isRunning, let start = agent.startedAt {
                RemainingTimeLabel(kind: "agent", startedAt: start).padding(.horizontal, 20).padding(.vertical, 6)
            }
            if let approval = agent.pendingApproval { approvalCard(approval) }
            Divider()
            composer
        }
        .onAppear { if link.devices.isEmpty { showsRemote = true } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("エージェント").font(.harness(.title2, weight: .bold))
                Text("この Mac のアプリや Safari を、AI が画面を読みながら一手ずつ操作します。送信・購入・削除などの前には毎回確認し、パスワードは入力しません。")
                    .font(.harness(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                status(agent.hasAccessibilityPermission, "画面の操作", "システム設定 > プライバシーとセキュリティ > アクセシビリティ で許可が要ります")
                status(agent.searchInstalled, "手元の検索(RustXNG)", "未導入: 検索は Safari で開いて読みます")
                Button {
                    showsRemote.toggle()
                } label: {
                    Label(link.isEnabled ? "iPhone から: 受付中(\(link.connectedCount))" : "iPhone とつなぐ", systemImage: "iphone.radiowaves.left.and.right")
                        .font(.harness(.subheadline, weight: .semibold))
                }
                // 2026-11-04, the user could not find where to pair an iPhone: a real button, and the card open by itself
                // until one is paired.
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func status(_ ok: Bool, _ title: String, _ help: String) -> some View {
        Label(title, systemImage: ok ? "checkmark.circle" : "exclamationmark.triangle")
            .font(.harness(.caption, weight: .semibold))
            .foregroundStyle(ok ? .green : .orange)
            .help(ok ? title : help)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("頼めることの例").font(.harness(.headline))
            ForEach(["Safari で今日の東京の天気を調べて教えて", "メモに「買い物リスト」という新しいメモを作って、牛乳と卵を書いて",
                     "Swift の Observation について調べて、要点を 3 つにまとめて"], id: \.self) { example in
                Button(example) { agent.draft = example }.buttonStyle(.link)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func row(_ entry: AgentEntry) -> some View {
        switch entry.kind {
        case .request:
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(entry.text).font(.harness(.body)).textSelection(.enabled)
                    if entry.source == .remote { Text("遠隔から").font(.harness(.caption)).foregroundStyle(.secondary) }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            }
        case .step:
            Label {
                Text("\(entry.text) → \(entry.detail)").font(.harness(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
            } icon: { Image(systemName: "cursorarrow.click.2").foregroundStyle(.secondary) }
        case .approval:
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("確認: \(entry.text)").font(.harness(.caption, weight: .semibold))
                    Text(entry.detail).font(.harness(.caption)).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "exclamationmark.shield").foregroundStyle(.orange) }
        case .question, .outcome:
            Text(entry.text).font(.harness(.body)).textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func approvalCard(_ approval: AgentStore.Approval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("この操作をしてよいですか", systemImage: "exclamationmark.shield").font(.harness(.subheadline, weight: .semibold))
            Text(approval.action).font(.harness(.body))
            Text(approval.reason).font(.harness(.caption)).foregroundStyle(.secondary)
            HStack {
                Button("する") { agent.handle(.approve(approval.id, true)) }.buttonStyle(.borderedProminent)
                Button("しない(止める)") { agent.handle(.approve(approval.id, false)) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Mac でしてほしいことを書いてください", text: $agent.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit { agent.send() }
            if agent.isRunning {
                Button("止める") { agent.handle(.interrupt) }
            } else {
                Button("送る") { agent.send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Menu {
                    Button("会話を消す", role: .destructive) { agent.clear() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 30)
            }
        }
        .padding(14)
    }
}
