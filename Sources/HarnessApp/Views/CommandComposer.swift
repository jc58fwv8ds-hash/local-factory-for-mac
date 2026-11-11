import PhotosUI
import HarnessCore
import SwiftUI
import UniformTypeIdentifiers

struct CommandComposer: View {
    @Bindable var store: WorkspaceStore
    @State private var isShowingImageImporter = false
    @State private var isShowingDocumentImporter = false
    @State private var isShowingFolderImporter = false
    @State private var isShowingVoiceImporter = false
    @State private var isShowingPhotoLibrary = false
    @State private var photoItems: [PhotosPickerItem] = []
    @FocusState private var fieldIsFocused: Bool
    @AppStorage(VideoLength.settingKey) private var videoSeconds = VideoLength.defaultSeconds
    @AppStorage(VideoSpeech.settingKey) private var videoSpeech = VideoSpeech.auto
    @AppStorage(VideoSpeech.scriptKey) private var videoScript = ""

    private var instructionIsEmpty: Bool {
        store.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var actionColor: Color {
        if store.isGenerating { return .orange }
        return instructionIsEmpty ? .secondary.opacity(0.3) : .accentColor
    }

    var body: some View {
        VStack(spacing: 0) {
            VisualAttachmentStrip(session: store.visualAttachments) {
                store.removeVisualAttachment($0)
            }
            if !store.documentAttachments.isEmpty { documentStrip }
            if let voice = store.attachedVoice { voiceChip(voice) }
            if store.workspaceMode == .chat, store.composerPurpose == .video, videoSpeech == .script, store.attachedVoice == nil {
                scriptEditor
            }
            if let folder = store.attachedFolder {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(folder.lastPathComponent).font(.harness(.caption, weight: .medium))
                    Text("「名前を連番にして」のように頼めます").font(.harness(.caption2)).foregroundStyle(.secondary)
                    Button { store.attachedFolder = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("フォルダの添付をやめる")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if store.voiceConversation.showsStatus {
                VoiceConversationStatus(store: store)
            } else if store.voiceCapture.showsStatus {
                VoiceTranscriptStatus(store: store)
            }

            // The field has the whole width above the controls (2026-11-04: squeezed beside them it was a small part of the
            // card, and clicks on the rest of the card did nothing, which looked like input not working).
            VStack(alignment: .leading, spacing: 3) {
                if store.isGenerating {
                    HStack(spacing: 8) {
                        Text(store.generationStatusMessage)
                            .font(.harness(.caption2))
                            .foregroundStyle(.secondary)
                        if let start = store.generationStartedAt { RemainingTimeLabel(kind: store.generationJobKind, startedAt: start) }
                    }
                }
                StageLine(indicator: .shared)
                TextField(
                    store.workspaceMode == .chat ? "メッセージを入力" : "指示を入力",
                    text: $store.instruction,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .focused($fieldIsFocused)
                .accessibilityIdentifier(HarnessAccessibilityID.commandField)
                .lineLimit(1...6)
                .disabled(store.isGenerating)
                .onSubmit { store.submitInstruction() }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { fieldIsFocused = true }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            HStack(alignment: .center, spacing: 12) {
                Menu {
                    Button("写真ライブラリから選ぶ", systemImage: "photo.on.rectangle") {
                        isShowingPhotoLibrary = true
                    }
                    Button("画像ファイルを選ぶ", systemImage: "photo") {
                        isShowingImageImporter = true
                    }
                    Button("クリップボードから貼る", systemImage: "doc.on.clipboard") {
                        store.pasteVisualAttachment()
                    }
                    Divider()
                    Button("文書を選ぶ(PDF・Word・Excel・CSV)", systemImage: "doc.text") {
                        isShowingDocumentImporter = true
                    }
                    Button("フォルダを選ぶ(名前の一括変更など)", systemImage: "folder") {
                        isShowingFolderImporter = true
                    }
                    Button("セリフの音声ファイルを選ぶ(動画の口を合わせる)", systemImage: "waveform") {
                        isShowingVoiceImporter = true
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.harness(size: 16, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .disabled(store.isGenerating || store.visualAttachments.isImporting)
                .help("画像・文書・セリフの音声ファイルを添付")
                .accessibilityIdentifier(HarnessAccessibilityID.commandImageAdd)
                .photosPicker(isPresented: $isShowingPhotoLibrary, selection: $photoItems, maxSelectionCount: 4, matching: .images)
                .onChange(of: photoItems) { _, items in importPhotos(items) }

                // Purposes exist in chat mode only; code mode is always a conversation that may become a code change.
                if store.workspaceMode == .chat {
                    Menu {
                        ForEach(store.availablePurposes) { purpose in
                            Button(purpose.title, systemImage: purpose.symbol) { store.composerPurpose = purpose }
                        }
                    } label: {
                        Label(store.composerPurpose.title, systemImage: store.composerPurpose.symbol)
                            .font(.harness(.caption, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("次のメッセージの用途。文章・画像・動画は「AIモデル」の「用途ごとのモデル」で選んだモデルを使います")
                    PurposeModelChip(purpose: store.composerPurpose, settings: store.purposeSettings)
                    if store.composerPurpose == .video {
                        Picker("長さ", selection: $videoSeconds) {
                            ForEach(VideoLength.choices, id: \.self) { Text("\($0) 秒").tag($0) }
                        }
                        .fixedSize()
                        .font(.harness(.caption))
                        .help("動画の長さ。指示に「10秒」と書いても指定できます。画像を添付すると、その画像の人物から始まる動画を作ります(対応するモデル)")
                        // What the video says and whether a voice file goes with it, in sight (2026-11-10, the user: 「音声を
                        // 添付の有無とセリフ設定の有無を選べると良いね」).
                        Picker("セリフ", selection: $videoSpeech) {
                            ForEach(VideoSpeech.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .font(.harness(.caption))
                        .disabled(store.attachedVoice != nil)
                        .help("おまかせ: 指示にセリフや声があれば作ります。セリフなし: 動画の音だけ。セリフを入力: 書いたセリフを話す人ごとに別の声で読みます。音声ファイルを添付したときはそれを使います")
                        .accessibilityIdentifier(HarnessAccessibilityID.composerVideoSpeech)
                        Button { isShowingVoiceImporter = true } label: {
                            Label(store.attachedVoice == nil ? "音声を添付" : "音声あり", systemImage: "waveform")
                                .font(.harness(.caption))
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.isGenerating)
                        .help("セリフの音声ファイルを添付します。動画の口をその声に合わせます")
                    }
                }

                ContinuityCameraButton { data, name in
                    store.importVisualImageData(data, displayName: name, source: .continuityCamera)
                }
                .frame(width: 28, height: 28)
                .disabled(store.isGenerating || store.visualAttachments.isImporting)

                VoiceConversationControl(store: store)
                VoiceInputControl(store: store)

                Spacer(minLength: 0)

                ComposerAutopilotButton(store: store)

                Button {
                    if store.isGenerating {
                        store.stopGeneration()
                    } else {
                        store.submitInstruction()
                    }
                } label: {
                    Image(systemName: store.isGenerating ? "stop.fill" : "arrow.up")
                        .font(.harness(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(actionColor, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!store.isGenerating && (instructionIsEmpty || store.visualAttachments.isImporting))
                .help(store.isGenerating ? "生成を停止" : "AIへ送信")
                .accessibilityIdentifier(HarnessAccessibilityID.commandSubmit)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.regularMaterial)
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(.quaternary)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .fileImporter(
            isPresented: $isShowingImageImporter,
            allowedContentTypes: [.png, .jpeg, .webP, .heic, .heif],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                store.importVisualFiles(urls, source: .filePicker)
            }
        }
        .fileImporter(
            isPresented: $isShowingDocumentImporter,
            allowedContentTypes: DocumentReader.contentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { store.attachDocuments(urls) }
        }
        .alert("確認", isPresented: Binding(get: { store.pendingConsent != nil }, set: { if !$0 { store.pendingConsent = nil } }),
               presenting: store.pendingConsent) { pending in
            Button("続ける") { store.consentGiven(pending) }
            Button("やめる", role: .cancel) { store.pendingConsent = nil }
        } message: { pending in
            Text(pending.reason)
        }
        .fileImporter(isPresented: $isShowingVoiceImporter, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { store.attachVoice(url) }
        }
        .fileImporter(isPresented: $isShowingFolderImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.attachFolder(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !store.isGenerating else { return false }
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            folders.first.map(store.attachFolder)
            let voices = urls.filter(WorkspaceStore.isVoiceFile)
            voices.first.map(store.attachVoice)
            let files = urls.filter { !folders.contains($0) && !voices.contains($0) }
            let documents = files.filter(DocumentReader.isDocument)
            let images = files.filter { !DocumentReader.isDocument($0) }
            if !documents.isEmpty { store.attachDocuments(documents) }
            if !images.isEmpty { store.importVisualFiles(images, source: .dragAndDrop) }
            return true
        }
    }

    /// The lines for the next video, one per row as 「名前: セリフ」; each name gets a voice of their own.
    private var scriptEditor: some View {
        let lines = VideoScript.parse(videoScript)
        let speakers = VideoScript.speakers(lines).filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                Text("セリフ").font(.harness(.caption, weight: .medium))
                Text(speakers.isEmpty ? "1行に「名前: セリフ」。名前ごとに別の声になります(男・夫・彼氏などの名前は男性の声)"
                     : "\(lines.count) 行・\(speakers.count) 人(\(speakers.joined(separator: "、")))")
                    .font(.harness(.caption2)).foregroundStyle(.secondary)
            }
            TextEditor(text: $videoScript)
                .font(.harness(.body))
                .frame(minHeight: 54, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier(HarnessAccessibilityID.composerVideoScript)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// The attached voice file: its name and length; the next video's mouth moves to it.
    private func voiceChip(_ voice: AttachedVoice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
            Text(voice.name).font(.harness(.caption, weight: .medium)).lineLimit(1).truncationMode(.middle)
            if let seconds = voice.seconds { Text("\(Int(seconds.rounded())) 秒").font(.harness(.caption2)).foregroundStyle(.secondary) }
            Text("次の動画のセリフになります(口の動きを合わせます)").font(.harness(.caption2)).foregroundStyle(.secondary)
            Button { store.removeVoice() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help("音声ファイルの添付をやめる")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Attached documents as small chips: name, what was read, and a remove button.
    private var documentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.documentAttachments) { document in
                    HStack(spacing: 6) {
                        Image(systemName: document.kind == "PDF" ? "doc.richtext" : document.kind == "Excel" ? "tablecells" : "doc.text")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(document.displayName).font(.harness(.caption, weight: .medium)).lineLimit(1)
                            Text("\(document.kind)・\(document.summary)").font(.harness(.caption2)).foregroundStyle(.secondary)
                        }
                        Button { store.removeDocument(document.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .help("添付をやめる")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    /// Photos library picks arrive as transferable items; each is read as image data and attached like a pasted image.
    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        Task {
            for (index, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                store.importVisualImageData(data, displayName: "画像 \(index + 1)", source: .photoLibrary)
            }
        }
    }
}

/// Where the running job is spending its time; after it ends, how it went, until the next one begins.
private struct StageLine: View {
    var indicator: InferenceIndicator

    var body: some View {
        TimelineView(.periodic(from: .now, by: indicator.isActive ? 0.25 : 3600)) { context in
            let text = indicator.stages.summary(at: context.date)
            if !text.isEmpty {
                Text(text)
                    .font(.harness(.caption2))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }
}
