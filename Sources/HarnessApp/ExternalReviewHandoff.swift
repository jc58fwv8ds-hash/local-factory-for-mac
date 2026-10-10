import AppKit
import Foundation

@MainActor
protocol ExternalReviewHandoffProviding: AnyObject {
    func copy(_ content: String)
    func openChatGPT() -> Bool
}

@MainActor
final class SystemExternalReviewHandoff: ExternalReviewHandoffProviding {
    func copy(_ content: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    func openChatGPT() -> Bool {
        guard let url = URL(string: "https://chatgpt.com/") else { return false }
        return NSWorkspace.shared.open(url)
    }
}
