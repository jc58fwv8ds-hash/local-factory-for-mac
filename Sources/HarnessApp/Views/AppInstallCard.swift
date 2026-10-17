import AppKit
import SwiftUI

/// The card under 「◯◯をインストールして」 (#49): Homebrew cask candidates with where each comes from; install only on
/// the button, then the signature and notarization checks.
struct AppInstallCard: View {
    let change: AppInstallChange
    @Bindable var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                Text("アプリのインストール").font(.harness(.subheadline, weight: .semibold))
                Text(change.query).font(.harness(.caption)).foregroundStyle(.secondary)
                Spacer()
            }
            switch change.status {
            case .searching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Homebrew で候補を探しています。まだ何もダウンロードしていません。").font(.harness(.caption)).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.harness(.caption)).foregroundStyle(.secondary)
            case .discarded:
                Text("インストールはやめました。").font(.harness(.caption)).foregroundStyle(.secondary)
            case .ready, .installing:
                ForEach(change.candidates) { candidate in
                    Button { if change.status == .ready { change.selected = candidate.token } } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: change.selected == candidate.token ? "largecircle.fill.circle" : "circle")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(candidate.name)  \(candidate.version)").font(.harness(.caption, weight: .semibold))
                                if !candidate.summary.isEmpty { Text(candidate.summary).font(.harness(.caption)) }
                                Text("公式サイト: \(candidate.homepage)").font(.harness(.caption)).foregroundStyle(.secondary)
                                Text("ダウンロード元: \(candidate.downloadHost)").font(.harness(.caption)).foregroundStyle(.secondary)
                                if !candidate.hasChecksum {
                                    Text("この配布物はチェックサムで確かめられません(配布元が版ごとの値を出していません)")
                                        .font(.harness(.caption)).foregroundStyle(.orange)
                                }
                                if candidate.installed { Text("すでに入っています").font(.harness(.caption)).foregroundStyle(.secondary) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .background(Color.primary.opacity(change.selected == candidate.token ? 0.07 : 0.03), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack(spacing: 8) {
                    if change.status == .installing {
                        ProgressView().controlSize(.small)
                        Text("インストールしています(Homebrew がダウンロードを確かめてから入れます)").font(.harness(.caption))
                    } else {
                        Button("インストールする") { Task { await store.installApp(change) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(change.selected == nil)
                        Button("やめる") { store.discardAppInstall(change) }
                    }
                }
                .controlSize(.small)
            case .installed(let checks):
                ForEach(checks, id: \.app) { check in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: check.app).lastPathComponent).font(.harness(.caption, weight: .semibold))
                        Text("署名: \(check.signed ? "確認済み" : "確認できません")、Apple の公証: \(check.notarized ? "確認済み" : "確認できません")")
                            .font(.harness(.caption)).foregroundStyle(check.signed && check.notarized ? Color.secondary : Color.orange)
                    }
                }
                if let first = checks.first {
                    Button("開く") { NSWorkspace.shared.open(URL(fileURLWithPath: first.app)) }.controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}
