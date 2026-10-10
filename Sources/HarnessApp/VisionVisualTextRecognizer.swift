import Foundation
import HarnessCore
import ImageIO
import Vision

protocol VisualTextRecognizing: Sendable {
    func recognizeText(
        in data: Data,
        descriptor: VisualAttachmentDescriptor
    ) throws -> VisualTextTranscript?
}

struct VisionVisualTextRecognizer: VisualTextRecognizing {
    func recognizeText(
        in data: Data,
        descriptor: VisualAttachmentDescriptor
    ) throws -> VisualTextTranscript? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
        let image = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { return nil }

        let orientation = CGImagePropertyOrientation(
            rawValue: UInt32(descriptor.orientation.rawValue)
        ) ?? .up
        var lastError: (any Error)?
        for attempt in 0..<2 {
            do {
                let lines = try recognizeLines(in: image, orientation: orientation)
                if !lines.isEmpty {
                    return VisualTextTranscript(
                        attachmentID: descriptor.id,
                        displayName: descriptor.displayName,
                        lines: lines
                    )
                }
            } catch {
                lastError = error
            }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.04) }
        }
        if let lastError { throw lastError }
        return nil
    }

    private func recognizeLines(
        in image: CGImage,
        orientation: CGImagePropertyOrientation
    ) throws -> [VisualRecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.customWords = [
            "Harness", "Local Factory", "Qwen", "Ollama", "LM Studio", "SwiftUI", "Xcode",
            "iPhone", "Apple Watch", "watchOS", "macOS", "JSON"
        ]
        request.minimumTextHeight = 0.0025
        try VNImageRequestHandler(
            cgImage: image,
            orientation: orientation,
            options: [:]
        ).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(2).first.map { candidate in
                VisualRecognizedLine(
                    text: candidate.string,
                    confidence: Double(candidate.confidence),
                    bounds: VisualNormalizedRect(
                        x: observation.boundingBox.minX,
                        y: observation.boundingBox.minY,
                        width: observation.boundingBox.width,
                        height: observation.boundingBox.height
                    )
                )
            }
        }.sorted { lhs, rhs in
            let lhsTop = lhs.bounds.y + lhs.bounds.height
            let rhsTop = rhs.bounds.y + rhs.bounds.height
            return abs(lhsTop - rhsTop) > 0.01
                ? lhsTop > rhsTop
                : lhs.bounds.x < rhs.bounds.x
        }
    }
}
