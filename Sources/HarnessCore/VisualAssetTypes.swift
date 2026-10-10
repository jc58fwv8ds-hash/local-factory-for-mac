import Foundation

public enum VisualAssetFormat: String, Codable, CaseIterable, Equatable, Sendable {
    case png
    case jpeg
    case webP
    case heic

    public init?(filenameExtension: String) {
        switch filenameExtension.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "webp": self = .webP
        case "heic", "heif": self = .heic
        default: return nil
        }
    }

    public var mimeType: String {
        switch self {
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        case .webP: "image/webp"
        case .heic: "image/heic"
        }
    }
}

public enum VisualAttachmentSource: String, Codable, Equatable, Sendable {
    case filePicker
    case dragAndDrop
    case pasteboard
    case simulatorScreenshot
    case generated
    case photoLibrary
    case continuityCamera
}

public enum VisualAssetColorSpace: String, Codable, Equatable, Sendable {
    case sRGB
    case displayP3
    case grayGamma22
    case other
    case unknown
}

public enum VisualAssetOrientation: Int, Codable, Equatable, Sendable {
    case up = 1
    case upMirrored = 2
    case down = 3
    case downMirrored = 4
    case leftMirrored = 5
    case right = 6
    case rightMirrored = 7
    case left = 8
}

public enum VisualMetadataDisposition: String, Codable, Equatable, Sendable {
    case retainedLocalOnly
    case stripped
}

/// Content-free metadata. Image bytes belong to a managed asset store, never workspace JSON.
public struct VisualAttachmentDescriptor: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let displayName: String
    public let format: VisualAssetFormat
    public let byteCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let contentHash: String
    public let source: VisualAttachmentSource
    public let colorSpace: VisualAssetColorSpace
    public let orientation: VisualAssetOrientation
    public let metadataDisposition: VisualMetadataDisposition

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        displayName: String,
        format: VisualAssetFormat,
        byteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        contentHash: String,
        source: VisualAttachmentSource,
        colorSpace: VisualAssetColorSpace = .unknown,
        orientation: VisualAssetOrientation = .up,
        metadataDisposition: VisualMetadataDisposition = .retainedLocalOnly
    ) {
        self.id = id
        self.createdAt = createdAt
        self.displayName = displayName
        self.format = format
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.contentHash = contentHash
        self.source = source
        self.colorSpace = colorSpace
        self.orientation = orientation
        self.metadataDisposition = metadataDisposition
    }
}

public struct VisualNormalizedRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum VisualEditOperation: Codable, Equatable, Sendable {
    case trimUniformMargins(tolerance: Double)
    case crop(rect: VisualNormalizedRect)
    case resize(maxPixelDimension: Int)
    case tone(brightness: Double, contrast: Double, saturation: Double, warmth: Double)
    case removeBackground
    case generative(prompt: String)

    public var requiresGenerativeModel: Bool {
        if case .generative = self { return true }
        return false
    }
}

/// A non-destructive recipe. Applying it creates a new immutable revision.
public struct VisualEditRecipe: Codable, Equatable, Sendable {
    public let sourceContentHash: String
    public let operations: [VisualEditOperation]

    public init(sourceContentHash: String, operations: [VisualEditOperation]) {
        self.sourceContentHash = sourceContentHash
        self.operations = operations
    }
}
