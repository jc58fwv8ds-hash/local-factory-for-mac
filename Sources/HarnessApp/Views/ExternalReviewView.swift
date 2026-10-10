import HarnessCore
import SwiftUI

struct ExternalReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: ExternalReviewSession
    let onImport: (String) -> Void

    init(
        project: HarnessProject,
        rootPath: String,
        report: ProjectValidationReport,
        analysis: BuildFailureAnalysis?,
        sourceProvider: any ProjectSourceContextProviding,
        handoff: any ExternalReviewHandoffProviding,
        onImport: @escaping (String) -> Void
    ) {
        _session = State(
            initialValue: ExternalReviewSession(
                project: project,
                rootPath: rootPath,
                report: report,
                analysis: analysis,
                sourceProvider: sourceProvider,
                handoff: handoff
            )
        )
        self.onImport = onImport
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    privacyNotice
                    packetSection
                    responseSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 680)
        .task { await session.prepare() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.harness(.title2))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("通常ChatGPTで追加レビュー")
                    .font(.harness(.headline))
                    .accessibilityIdentifier(HarnessAccessibilityID.externalReview)
                Text("送信内容を確認し、結果をLocal Factoryへ戻す手動連携です。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("閉じる") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var privacyNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("自動送信しません", systemImage: "hand.raised.fill")
                .font(.harness(.subheadline, weight: .semibold))
            Text("成果物と検査結果は下で確認できます。資格情報らしき行と絶対パスを除外し、あなたがボタンを押したときだけクリップボードへコピーします。ChatGPT側での送信もあなたが行います。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var packetSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("レビュー依頼文", systemImage: "doc.text.magnifyingglass")
                    .font(.harness(.subheadline, weight: .semibold))
                Spacer()
                if let packet = session.packet {
                    Text("\(packet.includedSourceFileCount)ファイル ・ \(packet.content.count)文字")
                        .font(.harness(.caption2).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if session.isPreparing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("成果物と検査結果から安全なレビュー包を作っています…")
                        .font(.harness(.caption))
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else if let packet = session.packet {
                ScrollView([.horizontal, .vertical]) {
                    Text(packet.content)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 180, maxHeight: 260)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))

                HStack(spacing: 8) {
                    if packet.redactedLineCount > 0 {
                        Label("\(packet.redactedLineCount)行を除外", systemImage: "eye.slash")
                    }
                    if packet.wasTruncated {
                        Label("容量上限で一部省略", systemImage: "scissors")
                    }
                }
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)
            }

            if let warning = session.preparationWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.harness(.caption))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("ChatGPTの回答を戻す", systemImage: "arrow.uturn.backward.circle")
                .font(.harness(.subheadline, weight: .semibold))
            Text("ChatGPTの回答をここへ貼り付けると、Local Factoryの会話履歴へ修正案として取り込みます。ファイルは変更しません。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
            TextEditor(text: $session.importedResponse)
                .font(.harness(.body))
                .frame(minHeight: 130)
                .padding(7)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
                .accessibilityIdentifier(HarnessAccessibilityID.externalReviewResponse)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = session.handoffMessage {
                Text(message)
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("依頼文だけコピー") { session.copyReviewRequest() }
                    .disabled(session.packet == nil)
                Spacer()
                Button("コピーしてChatGPTを開く") {
                    session.copyAndOpenChatGPT()
                }
                .buttonStyle(.bordered)
                .disabled(session.packet == nil)
                .accessibilityIdentifier(HarnessAccessibilityID.externalReviewOpen)
                Button("回答をLocal Factoryへ取り込む") {
                    onImport(session.importedResponse)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canImport)
                .accessibilityIdentifier(HarnessAccessibilityID.externalReviewImport)
            }
        }
        .padding(16)
    }
}
