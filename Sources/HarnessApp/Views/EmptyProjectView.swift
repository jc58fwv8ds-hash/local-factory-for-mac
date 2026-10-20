import SwiftUI

/// The main area when the current mode has no selected project: start a chat, or start / open a project.
struct EmptyProjectView: View {
    @Bindable var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: store.workspaceMode == .chat ? "bubble.left.and.text.bubble.right" : "folder.badge.plus")
                .font(.harness(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
            if store.workspaceMode == .chat {
                Text("チャットを始めましょう")
                    .font(.harness(.title2, weight: .bold))
                Text("会話・文章・画像・動画はここで。アプリを作るときは上の「コード」に切り替えます。")
                    .font(.harness(.subheadline))
                    .foregroundStyle(.secondary)
                Button("新しいチャット") { store.startNewChat() }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("プロジェクトを始めましょう")
                    .font(.harness(.title2, weight: .bold))
                Text("新しく作るか、既存のソースフォルダをLocal Factoryへ追加できます。")
                    .font(.harness(.subheadline))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("プロジェクトを見る") {
                        store.selectedSection = .projects
                    }
                    .buttonStyle(.bordered)
                    Button("新規プロジェクト") {
                        store.isShowingNewProject = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(40)
    }
}
