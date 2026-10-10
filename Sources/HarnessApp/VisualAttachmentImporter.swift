import AppKit
import Foundation
import HarnessCore
import ImageIO
import UniformTypeIdentifiers

enum VisualAttachmentImportError: LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case multipleFrames(String)
    case invalidPreview(String)
    case policy(VisualAttachmentPolicyError)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            "\(name)を画像として読み込めませんでした。"
        case .unsupported(let name):
            "\(name)はPNG・JPEG・WebP・HEICのいずれかにしてください。"
        case .multipleFrames(let name):
            "\(name)は複数フレームを含むため、静止画像にしてから追加してください。"
        case .invalidPreview(let name):
            "\(name)の安全なプレビューを作れませんでした。"
        case .policy(let error):
            error.localizedDescription
        }
    }
}

struct ImportedVisualAttachment: Sendable {
    let descriptor: VisualAttachmentDescriptor
    let data: Data
    let previewData: Data
    let textInspection: VisualTextInspection
}

enum VisualTextInspection: Sendable {
    case found(VisualTextTranscript)
    case noText
    case unavailable

    var transcript: VisualTextTranscript? {
        if case .found(let transcript) = self { return transcript }
        return nil
    }
}

protocol VisualAttachmentImporting: Sendable {
    func importFiles(
        _ urls: [URL],
        source: VisualAttachmentSource
    ) async throws -> [ImportedVisualAttachment]

    func importData(
        _ data: Data,
        displayName: String,
        source: VisualAttachmentSource
    ) async throws -> ImportedVisualAttachment
}

actor SystemVisualAttachmentImporter: VisualAttachmentImporting {
    private let textRecognizer: any VisualTextRecognizing

    init(textRecognizer: any VisualTextRecognizing = VisionVisualTextRecognizer()) {
        self.textRecognizer = textRecognizer
    }

    func importFiles(
        _ urls: [URL],
        source: VisualAttachmentSource
    ) async throws -> [ImportedVisualAttachment] {
        guard urls.count <= VisualAttachmentPolicy.maximumAttachmentCount else {
            throw VisualAttachmentImportError.policy(
                .tooMany(maximum: VisualAttachmentPolicy.maximumAttachmentCount)
            )
        }
        return try urls.map { url in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            let name = url.lastPathComponent
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0,
                  size <= VisualAttachmentPolicy.maximumBytesPerImage else {
                throw VisualAttachmentImportError.unreadable(name)
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try makeAttachment(data: data, displayName: name, source: source)
        }
    }

    func importData(
        _ data: Data,
        displayName: String,
        source: VisualAttachmentSource
    ) async throws -> ImportedVisualAttachment {
        try makeAttachment(data: data, displayName: displayName, source: source)
    }

    private func makeAttachment(
        data: Data,
        displayName: String,
        source attachmentSource: VisualAttachmentSource
    ) throws -> ImportedVisualAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            throw VisualAttachmentImportError.unreadable(displayName)
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw VisualAttachmentImportError.multipleFrames(displayName)
        }
        guard let format = format(for: source) else {
            throw VisualAttachmentImportError.unsupported(displayName)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
              let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw VisualAttachmentImportError.unreadable(displayName)
        }
        let orientation = VisualAssetOrientation(
            rawValue: (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        ) ?? .up
        let swapsDimensions = orientation.rawValue >= 5
        let width = swapsDimensions ? rawHeight : rawWidth
        let height = swapsDimensions ? rawWidth : rawHeight
        let descriptor = VisualAttachmentDescriptor(
            displayName: displayName,
            format: format,
            byteCount: data.count,
            pixelWidth: width,
            pixelHeight: height,
            contentHash: VisualContentHash.sha256Hex(of: data),
            source: attachmentSource,
            colorSpace: colorSpace(in: properties),
            orientation: orientation,
            metadataDisposition: .retainedLocalOnly
        )
        if let error = VisualAttachmentPolicy.validationError(for: descriptor) {
            throw VisualAttachmentImportError.policy(error)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let preview = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ), let previewData = NSBitmapImageRep(cgImage: preview).representation(
            using: .png, properties: [:]
        ) else {
            throw VisualAttachmentImportError.invalidPreview(displayName)
        }
        let textInspection: VisualTextInspection
        do {
            textInspection = try textRecognizer.recognizeText(
                in: data,
                descriptor: descriptor
            ).map(VisualTextInspection.found) ?? .noText
        } catch {
            textInspection = .unavailable
        }
        return ImportedVisualAttachment(
            descriptor: descriptor,
            data: data,
            previewData: previewData,
            textInspection: textInspection
        )
    }

    private func format(for source: CGImageSource) -> VisualAssetFormat? {
        guard let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else { return nil }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .webP) { return .webP }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
        return nil
    }

    private func colorSpace(in properties: [CFString: Any]) -> VisualAssetColorSpace {
        let profile = (properties[kCGImagePropertyProfileName] as? String)?.lowercased() ?? ""
        if profile.contains("display p3") { return .displayP3 }
        if profile.contains("srgb") { return .sRGB }
        if profile.contains("gray") { return .grayGamma22 }
        return profile.isEmpty ? .unknown : .other
    }
}
