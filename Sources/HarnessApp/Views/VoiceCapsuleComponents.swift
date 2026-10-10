import HarnessCore
import SwiftUI

struct VoiceCapsuleCard: View {
    @Bindable var store: WorkspaceStore
    let manifest: VoiceCapsuleManifest
    @State private var isConfirmingDeletion = false
    @State private var isShowingTranscriptEditor = false

    private var reference: VoiceReferenceDescriptor? { manifest.references.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.badge.shield.lefthalf.filled")
                    .font(.harness(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Menu {
                    Button("声モデルを削除", role: .destructive) {
                        isConfirmingDeletion = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(manifest.displayName)
                    .font(.harness(.headline, weight: .semibold))
                    .accessibilityIdentifier(HarnessAccessibilityID.voiceCapsule(manifest.id))
                Text("端末内Voice Capsule")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                if let reference {
                    Text(sampleDetail(reference))
                        .font(.harness(.caption2))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Label(capsuleStatus, systemImage: capsuleStatusSymbol)
                .font(.harness(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            if reference?.transcriptContentHash == nil {
                Button("文字起こしを追加") {
                    isShowingTranscriptEditor = true
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(HarnessAccessibilityID.voiceCapsuleTranscriptAdd)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .confirmationDialog(
            "\(manifest.displayName)を削除しますか？",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("声モデルと見本音声を削除", role: .destructive) {
                Task { await store.removeVoiceCapsule(manifest) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("端末内に保存したVoice Capsuleを削除します。元のMP3は変更しません。")
        }
        .sheet(isPresented: $isShowingTranscriptEditor) {
            VoiceCapsuleTranscriptView(
                store: store,
                manifest: manifest,
                isPresented: $isShowingTranscriptEditor
            )
        }
    }

    private func sampleDetail(_ reference: VoiceReferenceDescriptor) -> String {
        let seconds = Double(reference.durationMilliseconds) / 1_000
        let transcript = reference.transcriptContentHash == nil ? "文字起こしなし" : "文字起こしあり"
        return String(format: "%.1f秒・%@・端末外へ共有しない", seconds, transcript)
    }

    private var capsuleStatus: String {
        guard reference?.transcriptContentHash != nil else {
            return "正確な文字起こしを追加すると利用可能"
        }
        return store.voiceEngine.readiness.canSynthesize
            ? "実音声テスト後に選択可能"
            : "Qwen3-TTSの準備が必要"
    }

    private var capsuleStatusSymbol: String {
        reference?.transcriptContentHash == nil
            ? "text.badge.xmark"
            : "clock.badge.checkmark"
    }
}
