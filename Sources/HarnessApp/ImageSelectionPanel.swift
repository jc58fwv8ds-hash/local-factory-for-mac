import AppKit
import UniformTypeIdentifiers
import Foundation

/// One picture from the Mac (2026-11-10: setting an iPhone app's icon).
@MainActor
enum ImageSelectionPanel {
    static func choose(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A prebuilt .xcframework to add to an iPhone app.
    static func chooseFramework() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "アプリに加える部品(.xcframework)を選びます。プロジェクトの Frameworks フォルダにコピーし、リンクと同梱を設定します。"
        panel.allowedContentTypes = [UTType(filenameExtension: "xcframework") ?? .package]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
