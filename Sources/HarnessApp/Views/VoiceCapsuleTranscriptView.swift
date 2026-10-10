import HarnessCore
import SwiftUI

struct VoiceCapsuleTranscriptView: View {
    @Bindable var store: WorkspaceStore
    let manifest: VoiceCapsuleManifest
    @Binding var isPresented: Bool
    @State private var transcript = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var canSave: Bool {
        !isSaving
            && VoiceCapsuleTranscriptPolicy.validationError(
                for: transcript,
                allowsEmpty: false
            ) == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Label("見本音声で実際に話している言葉を、そのまま入力してください", systemImage: "quote.bubble")
                    .font(.harness(.subheadline, weight: .semibold))
                Text("言い換えや要約ではなく、助詞や言いよどみも含めて音声と合わせると、声の再現が安定します。内容はこのMacだけに保存します。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                TextField(
                    "例：今日は新しいアイデアについて話します。",
                    text: $transcript,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(5...10)
                .accessibilityIdentifier(HarnessAccessibilityID.voiceCapsuleTranscriptAddField)
                HStack {
                    Text("一度追加した内容の編集は、次の安全な更新機能で対応します")
                        .font(.harness(.caption2))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(transcript.count) / \(VoiceCapsuleTranscriptPolicy.maximumCharacters)")
                        .font(.harness(.caption2))
                        .foregroundStyle(
                            transcript.count <= VoiceCapsuleTranscriptPolicy.maximumCharacters
                                ? Color.secondary
                                : Color.red
                        )
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.harness(.caption))
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
            Spacer()
            Divider()
            HStack {
                Label("見本音声と元MP3は変更しません", systemImage: "lock.shield")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル") { isPresented = false }
                Button(isSaving ? "保存中…" : "文字起こしを追加") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .accessibilityIdentifier(HarnessAccessibilityID.voiceCapsuleTranscriptAddSave)
            }
            .padding(20)
        }
        .frame(width: 620, height: 480)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("文字起こしを追加")
                    .font(.harness(.title3, weight: .semibold))
                Text(manifest.displayName)
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("閉じる") { isPresented = false }
        }
        .padding(20)
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            let saved = await store.addTranscript(transcript, to: manifest)
            isSaving = false
            if saved {
                isPresented = false
            } else {
                errorMessage = store.voiceCapsules.lastErrorMessage
                    ?? "文字起こしを追加できませんでした。"
            }
        }
    }
}
