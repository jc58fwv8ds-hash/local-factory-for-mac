import HarnessCore
import SwiftUI

struct AppleAppLibraryView: View {
    @Bindable var store: WorkspaceStore
    @State private var session: AppleAppLibrarySession
    @State private var isConfirmingInstall = false

    init(store: WorkspaceStore) {
        self.store = store
        _session = State(
            initialValue: AppleAppLibrarySession(
                sources: store.appleAppSources,
                provider: store.appleAppLibraryProvider
            )
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            library
            Divider().opacity(0.55)
            AppleAppInstallPanel(
                session: session,
                onOpenXcode: openSelectedAppInXcode,
                onInstall: { isConfirmingInstall = true }
            )
            .frame(width: 338)
        }
        .background {
            LinearGradient(
                colors: [Color(nsColor: .controlBackgroundColor), Color.accentColor.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .task {
            session.updateSources(store.appleAppSources)
            if session.apps.isEmpty && !session.isBusy {
                session.refresh()
            }
        }
        .onDisappear { session.stop() }
        .confirmationDialog(
            "選択した端末へインストールしますか？",
            isPresented: $isConfirmingInstall,
            titleVisibility: .visible
        ) {
            Button("無料署名でインストールして起動") {
                session.installSelected()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var library: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header
                feedback
                content
            }
            .padding(32)
        }
        .accessibilityIdentifier(HarnessAccessibilityID.appLibrary)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("アプリを選ぶ")
                        .font(.harness(.title, weight: .bold))
                    Text("iPhoneとApple Watchへ。難しい準備はLocal Factoryが整えます。")
                        .font(.harness(.subheadline))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    session.updateSources(store.appleAppSources)
                    session.refresh()
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(session.isBusy)
                .accessibilityIdentifier(HarnessAccessibilityID.appLibraryRefresh)
            }

            HStack(spacing: 8) {
                DeviceSummaryPill(
                    platform: .iPhone,
                    count: session.devices(for: .iPhone).count
                )
                DeviceSummaryPill(
                    platform: .appleWatch,
                    count: session.devices(for: .appleWatch).count
                )
                Spacer()
                if !session.apps.isEmpty {
                    Text("\(session.apps.count)個のアプリ")
                        .font(.harness(.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = session.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.harness(.caption))
                .foregroundStyle(.red)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        } else if let status = session.statusMessage, !session.apps.isEmpty {
            Label(status, systemImage: "checkmark.circle.fill")
                .font(.harness(.caption))
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.phase == .loading && session.apps.isEmpty {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Xcodeプロジェクトからアプリを見つけています…")
                    .font(.harness(.headline))
                Text("schemeや対応端末は背後で確認します。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        } else if store.appleAppSources.isEmpty {
            emptySourceState
        } else if session.apps.isEmpty {
            ContentUnavailableView(
                "インストールできるアプリがありません",
                systemImage: "square.stack.3d.up.slash",
                description: Text("Xcodeで共有schemeを作成してから、一覧を更新してください。")
            )
            .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220, maximum: 285), spacing: 18)],
                spacing: 18
            ) {
                ForEach(session.apps) { app in
                    AppleAppTile(
                        app: app,
                        isSelected: app.id == session.selectedAppID
                    ) {
                        session.selectApp(app.id)
                    }
                }
            }
        }
    }

    private var emptySourceState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.badge.a")
                .font(.harness(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("まずアプリのソースを追加します")
                .font(.harness(.title2, weight: .bold))
            Text("プロジェクトにXcodeのソースフォルダを接続すると、ここへ自動で並びます。")
                .font(.harness(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("プロジェクトを開く") { store.selectedSection = .projects }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private func openSelectedAppInXcode() {
        guard let rootPath = session.selectedApp?.source.rootPath else { return }
        do {
            try store.xcodeProjectOpener.openXcodeProject(rootPath: rootPath)
        } catch {
            session.present(error: error)
        }
    }

    private var confirmationMessage: String {
        let targets = session.installationOrder.map(\.displayName).joined(separator: "と")
        return "\(targets)向けに無料の開発用署名を行います。公開や課金は行わず、認証情報や端末IDも保存しません。"
    }
}

private struct DeviceSummaryPill: View {
    let platform: AppleAppPlatform
    let count: Int

    var body: some View {
        Label(
            count == 0 ? "\(platform.displayName) 未接続" : "\(platform.displayName) 接続済み",
            systemImage: platform == .iPhone ? "iphone.gen3" : "applewatch"
        )
        .font(.harness(.caption, weight: .semibold))
        .foregroundStyle(count == 0 ? Color.secondary : Color.green)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(.quaternary))
    }
}
