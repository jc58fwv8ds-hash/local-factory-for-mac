import Foundation
import HarnessCore

extension WorkspaceStore {
    func importVisualFiles(_ urls: [URL], source: VisualAttachmentSource) {
        visualAttachments.importFiles(urls, source: source)
    }

    func importVisualImageData(_ data: Data, displayName: String, source: VisualAttachmentSource) {
        visualAttachments.importImageData(data, displayName: displayName, source: source)
    }

    func pasteVisualAttachment() {
        visualAttachments.paste()
    }

    func removeVisualAttachment(_ id: UUID) {
        visualAttachments.remove(id)
    }
}
