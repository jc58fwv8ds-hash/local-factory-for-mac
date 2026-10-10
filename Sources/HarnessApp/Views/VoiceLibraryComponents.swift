import HarnessCore
import SwiftUI

struct VoiceProfileCard: View {
    @Bindable var store: WorkspaceStore
    let profile: VoiceModelProfile

    private var isSelected: Bool {
        store.voiceLibrary.selectedProfileID == profile.id
    }

    private var isPlaying: Bool {
        store.voiceLibrary.preview.playingProfileID == profile.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: profile.source == .includedPreset
                    ? "waveform.badge.sparkles" : "speaker.wave.2.fill")
                    .font(.harness(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Spacer()
                if isSelected {
                    Label("使用中", systemImage: "checkmark.circle.fill")
                        .font(.harness(.caption, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                } else if profile.isRemovable {
                    Menu {
                        Button("一覧から外す", role: .destructive) {
                            store.removeVoiceModel(profile)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(profile.displayName)
                    .font(.harness(.headline, weight: .semibold))
                Text(profile.summary)
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(profile.source == .includedPreset ? "Local Factoryプリセット" : profile.languageCode)
                    .font(.harness(.caption2, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            HStack {
                Button {
                    store.voiceLibrary.preview.toggle(profile)
                } label: {
                    Label(isPlaying ? "停止" : "試聴", systemImage: isPlaying ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                Spacer()
                if !isSelected {
                    Button("この声を使う") { store.selectVoiceModel(profile) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
        .background(
            isSelected ? Color.accentColor.opacity(0.09) : .secondary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
        }
        .accessibilityIdentifier(HarnessAccessibilityID.voiceProfile(profile.id))
    }
}

struct AddSystemVoiceView: View {
    @Bindable var store: WorkspaceStore
    @Binding var isPresented: Bool
    @State private var search = ""

    private var filteredVoices: [SystemVoiceOption] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.voiceLibrary.availableToAdd }
        return store.voiceLibrary.availableToAdd.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.languageCode.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Macの声を追加")
                        .font(.harness(.title3, weight: .semibold))
                    Text("Macにある音声への参照だけを保存します")
                        .font(.harness(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完了") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(HarnessAccessibilityID.voiceDone)
            }
            .padding(20)

            TextField("声の名前または言語を検索", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            Divider()

            if filteredVoices.isEmpty {
                ContentUnavailableView(
                    "追加できる声がありません",
                    systemImage: "waveform.slash",
                    description: Text(search.isEmpty ? "利用可能な音声はすべて追加済みです" : "検索する言葉を変えてみてください")
                )
            } else {
                List(filteredVoices) { voice in
                    let profile = VoiceModelCatalog.systemProfile(
                        identifier: voice.id,
                        name: voice.name,
                        languageCode: voice.languageCode
                    )
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.wave.2")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.name)
                                .font(.harness(.body, weight: .semibold))
                            Text("\(voice.languageCode) ・ \(voice.qualityLabel)")
                                .font(.harness(.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            store.voiceLibrary.preview.toggle(profile)
                        } label: {
                            Image(systemName: store.voiceLibrary.preview.playingProfileID == profile.id
                                ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .help("この声を試聴")
                        Button("追加") {
                            if store.addSystemVoice(voice) {
                                isPresented = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 5)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 620, height: 590)
        .onDisappear { store.voiceLibrary.preview.stop() }
    }
}
