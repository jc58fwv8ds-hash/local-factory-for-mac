import SwiftUI

/// 「おまかせで作る」 beside the code chat's send button (2026-11-10): the request becomes a plan of files that are built
/// and checked without more presses.
struct ComposerAutopilotButton: View {
    @Bindable var store: WorkspaceStore

    var body: some View {
        if store.workspaceMode == .code, !store.isGenerating, let record = store.library.selectedRecord,
           record.sourceLocation != nil {
            Button {
                AutopilotRequests.shared.request(store.instruction, projectID: record.id)
                store.instruction = ""
            } label: {
                Label("おまかせで作る", systemImage: "wand.and.stars")
                    .font(.harness(.caption, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(store.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("書いた内容から必要なファイルを考え、作って、ビルドとテストで確かめ、失敗したら直すまでを自動で進めます。")
            .accessibilityIdentifier(HarnessAccessibilityID.composerAutopilot)
        }
    }
}
