import HarnessCore
import SwiftUI
import UniformTypeIdentifiers

struct VoiceCapsuleCreationView: View {
    @Bindable var store: WorkspaceStore
    @Binding var isPresented: Bool
    @State private var isShowingImporter = false
    @State private var selectedURL: URL?
    @State private var inspection: VoiceSampleInspection?
    @State private var displayName = ""
    @State private var transcript = ""
    @State private var confirmsRights = false
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var canCreate: Bool {
        selectedURL != nil
            && inspection != nil
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayName.count <= 80
            && transcript.count <= VoiceCapsuleTranscriptPolicy.maximumCharacters
            && confirmsRights
            && !isWorking
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sourceSection
                    nameSection
                    transcriptSection
                    consentSection
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.harness(.caption))
                            .foregroundStyle(.red)
                    }
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 650, height: 700)
        .accessibilityIdentifier(HarnessAccessibilityID.voiceCapsuleCreator)
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: [.mp3]
        ) { result in
            if case .success(let url) = result { inspect(url) }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("MP3から声モデルを作る")
                    .font(.harness(.title3, weight: .semibold))
                Text("見本音声を端末内のVoice Capsuleとして保存します")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("閉じる") { isPresented = false }
        }
        .padding(20)
    }

    private var sourceSection: some View {
        formSection(title: "1　声の見本") {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    isShowingImporter = true
                } label: {
                    Label(
                        selectedURL == nil ? "MP3を選ぶ" : "別のMP3を選ぶ",
                        systemImage: "waveform.badge.plus"
                    )
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(HarnessAccessibilityID.voiceCapsuleChooseMP3)
                if isWorking && inspection == nil {
                    ProgressView("音声を確認しています…")
                        .controlSize(.small)
                } else if let inspection {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(inspection.displayName)
                                .font(.harness(.subheadline, weight: .semibold))
                            Text("\(inspection.durationLabel)・\(inspection.channelCount)ch・\(Int(inspection.sampleRate))Hz")
                                .font(.harness(.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("話し声がはっきりした3〜30秒、50MB以内のMP3を使ってください。保存時に24kHz・モノラルへ整えます。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var nameSection: some View {
        formSection(title: "2　声の名前") {
            TextField("例：自分の声", text: $displayName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(HarnessAccessibilityID.voiceCapsuleName)
            Text("\(displayName.count) / 80")
                .font(.harness(.caption2))
                .foregroundStyle(displayName.count <= 80 ? Color.secondary : Color.red)
        }
    }

    private var transcriptSection: some View {
        formSection(title: "3　見本音声の文字起こし（任意）") {
            TextField("話している内容をできるだけ正確に入力", text: $transcript, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .accessibilityIdentifier(HarnessAccessibilityID.voiceCapsuleTranscript)
            Text("保存だけなら空欄でも大丈夫です。Qwen3-TTSで声を再現するときは、正確な文字起こしが必要です。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
        }
    }

    private var consentSection: some View {
        formSection(title: "4　利用権限") {
            Toggle(isOn: $confirmsRights) {
                Text("私は本人、またはこの声を使う許可を受けた権利者です")
                    .font(.harness(.subheadline, weight: .semibold))
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier(HarnessAccessibilityID.voiceCapsuleConsent)
            Text("Local Factoryは権利を取得しません。Voice CapsuleはこのMacだけに保存し、合成音声であることを表示します。外部共有は話者確認が整うまで利用できません。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Label("元のMP3は変更しません", systemImage: "lock.shield")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
            Spacer()
            Button("キャンセル") { isPresented = false }
            Button(isWorking ? "作成中…" : "声モデルを作成") { create() }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
                .accessibilityIdentifier(HarnessAccessibilityID.voiceCapsuleCreate)
        }
        .padding(20)
    }

    private func formSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.harness(.headline, weight: .semibold))
            content()
        }
    }

    private func inspect(_ url: URL) {
        selectedURL = url
        inspection = nil
        errorMessage = nil
        displayName = url.deletingPathExtension().lastPathComponent
        isWorking = true
        Task {
            do {
                inspection = try await store.voiceCapsules.inspectMP3(at: url)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func create() {
        guard let selectedURL else { return }
        isWorking = true
        errorMessage = nil
        Task {
            let created = await store.createVoiceCapsule(
                from: selectedURL,
                displayName: displayName,
                transcript: transcript,
                confirmsRights: confirmsRights
            )
            isWorking = false
            if created {
                isPresented = false
            } else {
                errorMessage = store.voiceCapsules.lastErrorMessage
                    ?? "声モデルを作れませんでした。"
            }
        }
    }
}
