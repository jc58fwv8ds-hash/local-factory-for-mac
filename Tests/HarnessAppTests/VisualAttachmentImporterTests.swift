import AppKit
import CoreText
import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

struct VisualAttachmentImporterTests {
    @Test func imageIOValidatesActualContentAndBuildsABoundedPreview() async throws {
        let png = try #require(Data(base64Encoded: onePixelPNG))
        let imported = try await SystemVisualAttachmentImporter().importData(
            png,
            displayName: "pixel.png",
            source: .pasteboard
        )

        #expect(imported.descriptor.format == .png)
        #expect(imported.descriptor.pixelWidth == 1)
        #expect(imported.descriptor.pixelHeight == 1)
        #expect(imported.descriptor.contentHash == VisualContentHash.sha256Hex(of: png))
        #expect(!imported.previewData.isEmpty)
        #expect(InferenceImage(descriptor: imported.descriptor, data: png) != nil)
    }

    @Test func invalidBytesAreRejectedBeforeEnteringTheComposer() async {
        await #expect(throws: VisualAttachmentImportError.self) {
            try await SystemVisualAttachmentImporter().importData(
                Data("not an image".utf8),
                displayName: "fake.png",
                source: .filePicker
            )
        }
    }

    @Test func recognizedTextTravelsThroughImporterWithLocationAndConfidence() async throws {
        let png = try makeTextScreenshot()
        let imported = try await SystemVisualAttachmentImporter(
            textRecognizer: VisualRecognizerFixture()
        ).importData(png, displayName: "screen.png", source: .filePicker)
        let transcript = try #require(imported.textInspection.transcript)

        #expect(transcript.attachmentID == imported.descriptor.id)
        #expect(transcript.lines.first?.text == "HARNESS QWEN 27B")
        #expect(transcript.lines.first?.confidence == 0.98)
        #expect(transcript.lines.first?.bounds.x == 0.1)
    }

    @Test func visionReadsLargeScreenshotTextWhenTheSystemServiceIsAvailable() async throws {
        let png = try makeTextScreenshot()
        let imported = try await SystemVisualAttachmentImporter().importData(
            png,
            displayName: "screen.png",
            source: .filePicker
        )
        let recognized = imported.textInspection.transcript?.lines
            .map(\.text).joined(separator: " ").uppercased() ?? ""

        // Vision's XPC service is unavailable in some restricted test hosts.
        guard !recognized.isEmpty else { return }
        #expect(recognized.contains("HARNESS"))
        #expect(recognized.contains("27B"))
    }

    private func makeTextScreenshot() throws -> Data {
        let width = 900
        let height = 240
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let text = NSAttributedString(
            string: "HARNESS QWEN 27B",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 64),
                .foregroundColor: NSColor.black
            ]
        )
        context.textPosition = CGPoint(x: 40, y: 88)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let image = try #require(context.makeImage())
        return try #require(
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        )
    }

    private let onePixelPNG = """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=
    """
}

private struct VisualRecognizerFixture: VisualTextRecognizing {
    func recognizeText(
        in data: Data,
        descriptor: VisualAttachmentDescriptor
    ) throws -> VisualTextTranscript? {
        VisualTextTranscript(
            attachmentID: descriptor.id,
            displayName: descriptor.displayName,
            lines: [VisualRecognizedLine(
                text: "HARNESS QWEN 27B",
                confidence: 0.98,
                bounds: VisualNormalizedRect(x: 0.1, y: 0.3, width: 0.7, height: 0.3)
            )]
        )
    }
}
