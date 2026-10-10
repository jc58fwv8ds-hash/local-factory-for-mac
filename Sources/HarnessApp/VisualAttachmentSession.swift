import AppKit
import Foundation
import HarnessCore
import Observation

struct VisualAttachmentItem: Identifiable {
    let descriptor: VisualAttachmentDescriptor
    let data: Data
    let preview: NSImage
    let textInspection: VisualTextInspection

    var id: UUID { descriptor.id }
}

@MainActor
@Observable
final class VisualAttachmentSession {
    var items: [VisualAttachmentItem] = []
    var isImporting = false
    var errorMessage: String?

    @ObservationIgnored private let importer: any VisualAttachmentImporting
    @ObservationIgnored private let pasteboard: any VisualPasteboardProviding
    @ObservationIgnored private var importTask: Task<Void, Never>?

    init(
        importer: any VisualAttachmentImporting = SystemVisualAttachmentImporter(),
        pasteboard: any VisualPasteboardProviding = SystemVisualPasteboardProvider()
    ) {
        self.importer = importer
        self.pasteboard = pasteboard
    }

    var inferenceImages: [InferenceImage] {
        items.compactMap {
            InferenceImage(
                descriptor: $0.descriptor,
                data: $0.data,
                recognizedText: $0.textInspection.transcript
            )
        }
    }

    var descriptors: [VisualAttachmentDescriptor] { items.map(\.descriptor) }

    func importFiles(_ urls: [URL], source: VisualAttachmentSource) {
        beginImport {
            try await self.importer.importFiles(urls, source: source)
        }
    }

    /// Image bytes from the Photos library or an iPhone (Continuity Camera).
    func importImageData(_ data: Data, displayName: String, source: VisualAttachmentSource) {
        beginImport {
            [try await self.importer.importData(data, displayName: displayName, source: source)]
        }
    }

    func paste() {
        guard let content = pasteboard.content() else {
            errorMessage = "クリップボードに画像がありません。"
            return
        }
        switch content {
        case .fileURLs(let urls):
            importFiles(urls, source: .pasteboard)
        case .png(let data):
            beginImport {
                [try await self.importer.importData(
                    data,
                    displayName: "クリップボード.png",
                    source: .pasteboard
                )]
            }
        }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        errorMessage = nil
    }

    func clear() {
        importTask?.cancel()
        items = []
        isImporting = false
        errorMessage = nil
    }

    private func beginImport(
        operation: @escaping @Sendable () async throws -> [ImportedVisualAttachment]
    ) {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        importTask = Task { [weak self] in
            do {
                let imported = try await operation()
                try Task.checkCancellation()
                self?.append(imported)
            } catch is CancellationError {
                // A newer user action intentionally replaced the import.
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isImporting = false
            self?.importTask = nil
        }
    }

    private func append(_ imported: [ImportedVisualAttachment]) {
        let descriptors = items.map(\.descriptor) + imported.map(\.descriptor)
        if let error = VisualAttachmentPolicy.validationError(for: descriptors) {
            errorMessage = error.localizedDescription
            return
        }
        let newItems = imported.compactMap { payload -> VisualAttachmentItem? in
            guard let image = NSImage(data: payload.previewData) else { return nil }
            return VisualAttachmentItem(
                descriptor: payload.descriptor,
                data: payload.data,
                preview: image,
                textInspection: payload.textInspection
            )
        }
        guard newItems.count == imported.count else {
            errorMessage = "画像のプレビューを表示できませんでした。"
            return
        }
        items.append(contentsOf: newItems)
    }
}
