import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "iPhone で撮影": shows macOS's Continuity Camera menu (take photo, scan documents, add sketch) for nearby iPhones and
/// iPads, and hands the captured image back. AppKit fills the placeholder menu item with the devices; the button's view is
/// made first responder and acts as the services requestor that receives the image.
struct ContinuityCameraButton: NSViewRepresentable {
    let onImage: (Data, String) -> Void

    func makeNSView(context: Context) -> CaptureButton {
        let view = CaptureButton()
        view.onImage = onImage
        return view
    }

    func updateNSView(_ view: CaptureButton, context: Context) { view.onImage = onImage }

    final class CaptureButton: NSButton, @MainActor NSServicesMenuRequestor {
        var onImage: ((Data, String) -> Void)?

        init() {
            super.init(frame: .zero)
            image = NSImage(systemSymbolName: "camera", accessibilityDescription: "iPhone で撮影")
            isBordered = false
            imagePosition = .imageOnly
            toolTip = "iPhone で撮影・書類をスキャン"
            target = self
            action = #selector(showMenu)
            setAccessibilityLabel("iPhone で撮影")
        }

        required init?(coder: NSCoder) { nil }

        override var acceptsFirstResponder: Bool { true }

        @objc private func showMenu() {
            window?.makeFirstResponder(self)
            let menu = NSMenu()
            let devices = NSMenuItem(title: "iPhone から取り込む", action: nil, keyEquivalent: "")
            devices.identifier = NSMenuItem.importFromDeviceIdentifier
            menu.addItem(devices)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        }

        override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                     returnType: NSPasteboard.PasteboardType?) -> Any? {
            if let returnType, NSImage.imageTypes.contains(returnType.rawValue), sendType == nil { return self }
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }

        func readSelection(from pasteboard: NSPasteboard) -> Bool {
            if let data = pasteboard.data(forType: .png) {
                onImage?(data, "iPhone で撮影.png"); return true
            }
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) {
                onImage?(data, "iPhone で撮影.jpg"); return true
            }
            if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                onImage?(png, "iPhone で撮影.png"); return true
            }
            return false
        }

        func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
    }
}
