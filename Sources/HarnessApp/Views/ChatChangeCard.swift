import HarnessCore
import SwiftUI

/// The card under a chat message that asked for a code change: progress, changed files, 要確認, and apply / diff / undo.
struct ChatChangeCard: View {
    let change: ChatChange
    @Bindable var store: WorkspaceStore
    @State private var isShowingDiff = false
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                Text("修正案").font(.harness(.subheadline, weight: .semibold))
                Spacer()
                statusLabel
            }
            switch change.status {
            case .asking:
                ChatQuestionsSection(change: change, store: store)
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("計画 → 修正 → ビルド → テストを手元で実行しています。プロジェクトはまだ変更していません。")
                        .font(.harness(.caption)).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.harness(.caption)).foregroundStyle(.secondary).lineLimit(4)
            case .discarded:
                Text("この修正案は使いません(新しい指示に置き換えたか、やめました)。")
                    .font(.harness(.caption)).foregroundStyle(.secondary)
            case .ready, .applied:
                files
                if !change.cautions.isEmpty { cautions }
                if change.status == .ready && change.isChecking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("具体例で確かめています。結果はこのカードに追加します(適用はいつでもできます)。")
                            .font(.harness(.caption)).foregroundStyle(.secondary)
                    }
                }
                if change.status == .ready && !change.examples.isEmpty { examples }
                actions
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .sheet(isPresented: $isShowingDiff) { diffSheet }
    }

    private var statusLabel: some View {
        let (text, color): (String, Color) = switch change.status {
        case .asking: ("作る前の確認", .accentColor)
        case .running: ("作業中", .secondary)
        case .ready: ("テスト合格・まだ確かめていません", .green)
        case .applied: ("適用済み", .accentColor)
        case .failed: ("作れませんでした", .orange)
        case .discarded: ("取りやめ", .secondary)
        }
        return Text(text).font(.harness(.caption, weight: .medium)).foregroundStyle(color)
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(change.proposals, id: \.relativePath) { proposal in
                HStack {
                    Text(proposal.relativePath + (proposal.operation == .creation ? "(新規)" : ""))
                        .font(.harness(.caption).monospaced())
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("+\(proposal.summary.addedLineCount) −\(proposal.summary.removedLineCount)")
                        .font(.harness(.caption).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cautions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("要確認", systemImage: "exclamationmark.triangle").font(.harness(.caption, weight: .semibold))
            ForEach(change.cautions, id: \.self) { Text("・" + $0).font(.harness(.caption)) }
        }
        .foregroundStyle(.orange)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// "この動きで合っていますか": measured results in the user's words; 違う opens other readings as follow-up instructions.
    private var examples: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("この動きで合っていますか？").font(.harness(.caption, weight: .semibold))
            Text("依頼の境目にあたる場面を、修正したコードで実際に動かした結果です。")
                .font(.harness(.caption2)).foregroundStyle(.secondary)
            ForEach(change.examples) { example in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(example.situation) → \(example.quantity): ")
                            + Text(example.after).bold()
                        if let before = example.before, before != example.after {
                            Text("(変更前は \(before))").foregroundStyle(.secondary)
                        } else if example.before != nil {
                            Text("(変更前と同じ)").foregroundStyle(.secondary)
                        }
                    }
                    .font(.harness(.caption))
                    switch example.answer {
                    case nil:
                        HStack(spacing: 8) {
                            Button("合っている") { store.answerExample(example, in: change, .right) }
                            Button("違う") { store.answerExample(example, in: change, .wrong) }
                        }
                        .controlSize(.small)
                    case .right:
                        Label("確認済み", systemImage: "checkmark").font(.harness(.caption2)).foregroundStyle(.green)
                    case .wrong:
                        VStack(alignment: .leading, spacing: 4) {
                            Text(example.alternatives.isEmpty ? "正しい動きを下の入力欄に書いて送ると、この修正案に重ねて直します。"
                                 : "どう直しますか？ 選ぶと続きの指示として送り、この修正案に重ねて作り直します。")
                                .font(.harness(.caption2)).foregroundStyle(.secondary)
                            ForEach(example.alternatives, id: \.self) { alternative in
                                Button(alternative) { store.chooseAlternative(alternative, for: example) }
                                    .controlSize(.small)
                            }
                            if !example.alternatives.isEmpty {
                                Text("どれでもなければ、正しい動きを下の入力欄に書いて送ってください。")
                                    .font(.harness(.caption2)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if change.status == .ready {
                Button("適用する") { run { await store.applyChatChange(change) } }
                    .buttonStyle(.borderedProminent)
                Button("差分を見る") { isShowingDiff = true }
                Button("やめる") { store.discardChatChange(change) }
            } else {
                Button("差分を見る") { isShowingDiff = true }
                Button("取り消す") { run { await store.revertChatChange(change) } }
            }
        }
        .controlSize(.small)
        .disabled(isWorking)
    }

    private var diffSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("修正案の差分(\(change.proposals.count) ファイル)").font(.harness(.headline))
                Spacer()
                Button("閉じる") { isShowingDiff = false }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(change.proposals, id: \.relativePath) { proposal in
                        Text(proposal.relativePath).font(.harness(.caption, weight: .semibold).monospaced())
                        FileDiffPreview(proposal: proposal).frame(minHeight: 160, maxHeight: 360)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 720, height: 600)
    }

    private func run(_ operation: @escaping () async -> Void) {
        isWorking = true
        Task { await operation(); isWorking = false }
    }
}
