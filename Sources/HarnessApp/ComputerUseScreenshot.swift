import AppKit
import Foundation
import HarnessCore
import ScreenCaptureKit

/// The front window's picture for Computer Use stage 3 (2026-10-18): taken with ScreenCaptureKit (macOS asks the user for
/// screen recording permission the first time), scaled to at most 1280 pixels wide, PNG. The window's frame on screen is
/// kept so a click at (x, y) of the picture lands on the same place of the window.
enum ComputerUseScreenshot {
    struct Capture: Sendable {
        let png: Data
        /// Global display coordinates, top-left origin (the same as mouse events).
        let frame: CGRect
    }

    static func capture(processIdentifier: pid_t) async -> Capture? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows
                .filter({ $0.owningApplication?.processID == processIdentifier && $0.windowLayer == 0 && $0.frame.width > 80 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        let configuration = SCStreamConfiguration()
        let scale = min(1, 1280 / window.frame.width)
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        return Capture(png: png, frame: window.frame)
    }

    /// The picture as an image for the model.
    static func inferenceImages(_ png: Data?) async -> [InferenceImage] {
        guard let png, let imported = try? await SystemVisualAttachmentImporter()
            .importData(png, displayName: "screen.png", source: .generated) else { return [] }
        return InferenceImage(descriptor: imported.descriptor, data: imported.data).map { [$0] } ?? []
    }

    /// A left click at a global point.
    static func click(at point: CGPoint) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
}
