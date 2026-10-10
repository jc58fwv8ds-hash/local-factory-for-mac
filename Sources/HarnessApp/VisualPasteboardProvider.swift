import AppKit
import Foundation

enum VisualPasteboardContent {
    case fileURLs([URL])
    case png(Data)
}

protocol VisualPasteboardProviding {
    @MainActor func content() -> VisualPasteboardContent?
}

struct SystemVisualPasteboardProvider: VisualPasteboardProviding {
    @MainActor
    func content() -> VisualPasteboardContent? {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return .fileURLs(urls)
        }
        if let png = pasteboard.data(forType: .png) {
            return .png(png)
        }
        guard let tiff = pasteboard.data(forType: .tiff),
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            return nil
        }
        return .png(png)
    }
}
