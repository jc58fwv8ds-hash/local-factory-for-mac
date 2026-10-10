import AppKit
import Foundation

@MainActor
protocol DirectorySelectionProviding {
    func chooseDirectory(message: String, prompt: String) -> URL?
}

@MainActor
struct SystemDirectorySelectionPanel: DirectorySelectionProviding {
    func chooseDirectory(message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "作成先フォルダ"
        panel.message = message
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
