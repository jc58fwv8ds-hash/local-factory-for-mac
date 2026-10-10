import HarnessCore
import SwiftUI

struct VoiceLibraryView: View {
    @Bindable var store: WorkspaceStore
    @State private var isShowingAddVoice = false
    @State private var isShowingVoiceCapsuleCreator = false

    private let columns = [
        GridItem(.adaptive(minimum: 230, maximum: 310), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    selectedSummary
                    includedSection
                    if !store.voiceCapsules.manifests.isEmpty {
                        voiceCapsuleSection
                    }
                    if store.voiceLibrary.profiles.contains(where: { $0.source == .systemVoice }) {
                        addedSection
                    }
                    VoiceEngineStatusCard(store: store.voiceEngine)
                    if store.voiceEngine.readiness.canSynthesize {
                        VoiceEngineBenchmarkCard(
                            engineStore: store.voiceEngine,
                            capsules: store.voiceCapsules.manifests
                        )
                    }
                }
                .padding(28)
            }
        }
        .accessibilityIdentifier(HarnessAccessibilityID.voiceLibrary)
        .sheet(isPresented: $isShowingAddVoice) {
            AddSystemVoiceView(store: store, isPresented: $isShowingAddVoice)
        }
        .sheet(isPresented: $isShowingVoiceCapsuleCreator) {
            VoiceCapsuleCreationView(
                store: store,
                isPresented: $isShowingVoiceCapsuleCreator
            )
        }
        .onDisappear { store.voiceLibrary.preview.stop() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("音声ライブラリ")
                    .font(.harness(.title2, weight: .semibold))
                Text("Local Factoryが返答するときの声と話すテンポを選べます")
                    .font(.harness(.subheadline))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("MP3から声モデルを作る", systemImage: "waveform.badge.plus") {
                    isShowingVoiceCapsuleCreator = true
                }
                Button("Macの声を追加", systemImage: "speaker.wave.2") {
                    store.voiceLibrary.refresh()
                    isShowingAddVoice = true
                }
            } label: {
                Label("声を追加", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(HarnessAccessibilityID.voiceAdd)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var selectedSummary: some View {
        let selected = store.voiceLibrary.selectedProfile
        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 54, height: 54)
                Image(systemName: "waveform.circle.fill")
                    .font(.harness(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("いまの声")
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(selected.displayName)
                    .font(.harness(.title3, weight: .semibold))
                Text(selected.summary)
                    .font(.harness(.subheadline))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.voiceLibrary.preview.toggle(selected)
            } label: {
                Label(
                    store.voiceLibrary.preview.playingProfileID == selected.id ? "停止" : "試聴",
                    systemImage: store.voiceLibrary.preview.playingProfileID == selected.id
                        ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }

    private var includedSection: some View {
        voiceSection(
            title: "標準装備",
            detail: "追加作業なしですぐ使える、目的の異なる3つの声です",
            profiles: store.voiceLibrary.profiles.filter { $0.source == .includedPreset }
        )
    }

    private var addedSection: some View {
        voiceSection(
            title: "追加した声",
            detail: "Macにインストール済みの音声を参照します。音声データはLocal Factoryへ複製しません",
            profiles: store.voiceLibrary.profiles.filter { $0.source == .systemVoice }
        )
    }

    private var voiceCapsuleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自分の声モデル")
                .font(.harness(.headline, weight: .semibold))
            Text("許可を確認したMP3から作り、音声と設定をこのMacだけに保存します")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(store.voiceCapsules.manifests) { manifest in
                    VoiceCapsuleCard(store: store, manifest: manifest)
                }
            }
        }
    }

    private func voiceSection(
        title: String,
        detail: String,
        profiles: [VoiceModelProfile]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.harness(.headline, weight: .semibold))
            Text(detail)
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(profiles) { profile in
                    VoiceProfileCard(store: store, profile: profile)
                }
            }
        }
    }

}
