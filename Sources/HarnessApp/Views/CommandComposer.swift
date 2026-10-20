import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct CommandComposer: View {
    @Bindable var store: WorkspaceStore
    @State private var isShowingImageImporter = false
    @State private var isShowingDocumentImporter = false
    @State private var isShowingFolderImporter = false
    @State private var isShowingPhotoLibrary = false
    @State private var photoItems: [PhotosPickerItem] = []

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

            HStack(alignment: .bottom, spacing: 12) {
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
                } label: {
                    Image(systemName: "paperclip")
                        .font(.harness(size: 16, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .disabled(store.isGenerating || store.visualAttachments.isImporting)
                .help("画像や文書を添付")
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
                }

                ContinuityCameraButton { data, name in
                    store.importVisualImageData(data, displayName: name, source: .continuityCamera)
                }
                .frame(width: 28, height: 28)
                .disabled(store.isGenerating || store.visualAttachments.isImporting)

                VoiceConversationControl(store: store)
                VoiceInputControl(store: store)

                VStack(alignment: .leading, spacing: 3) {
                    if store.isGenerating {
                        Text(store.generationStatusMessage)
                            .font(.harness(.caption2))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("「続けよう」「この画像みたいに」など、いつもの言葉で大丈夫です")
                            .font(.harness(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        "このアプリをどう育てますか？",
                        text: $store.instruction,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier(HarnessAccessibilityID.commandField)
                    .lineLimit(1...4)
                    .disabled(store.isGenerating)
                    .onSubmit { store.submitInstruction() }
                }

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
            Button("同意を得ている") { store.continuePurposeInstruction(pending.instruction) }
            Button("やめる", role: .cancel) { store.pendingConsent = nil }
        } message: { pending in
            Text(pending.reason)
        }
        .fileImporter(isPresented: $isShowingFolderImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.attachFolder(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !store.isGenerating else { return false }
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            folders.first.map(store.attachFolder)
            let files = urls.filter { !folders.contains($0) }
            let documents = files.filter(DocumentReader.isDocument)
            let images = files.filter { !DocumentReader.isDocument($0) }
            if !documents.isEmpty { store.attachDocuments(documents) }
            if !images.isEmpty { store.importVisualFiles(images, source: .dragAndDrop) }
            return true
        }
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
                store.importVisualImageData(data, displayName: "写真 \(index + 1)", source: .photoLibrary)
            }
        }
    }
}
