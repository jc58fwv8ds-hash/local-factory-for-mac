import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sets an iPhone app's icon from any picture (2026-11-10: the 14Translate icon came as a rounded square with black
/// corners, and the scaffold had no asset catalog). The picture is cropped to its centre square, drawn opaque on white
/// (iOS rejects icons with transparency) at 1024×1024, and written into the AppIcon set as its single universal size.
public enum AppleAppIcon {
    public static let fileName = "AppIcon-1024.png"
    static let catalogContents = #"{"info":{"author":"xcode","version":1}}"# + "\n"

    static func iconSetContents(filename: String?) -> String {
        let file = filename.map { #""filename":"\#($0)","# } ?? ""
        return #"{"images":[{\#(file)"idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"# + "\n"
    }

    public enum Failure: LocalizedError, Equatable {
        case noIconSet, unreadable, unwritable
        public var errorDescription: String? {
            switch self {
            case .noIconSet: "アイコンの置き場所(Assets.xcassets/AppIcon.appiconset)が見つかりません。"
            case .unreadable: "画像を読み込めませんでした。"
            case .unwritable: "アイコンを書き出せませんでした。"
            }
        }
    }

    /// The AppIcon set inside the project, made in the app's folder when the project has an asset catalog without one.
    public static func iconSet(in root: URL) throws -> URL {
        let fileManager = FileManager.default
        let entries = fileManager.enumerator(at: root, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = entries?.nextObject() as? URL {
            if url.lastPathComponent == "AppIcon.appiconset" { return url }
            if url.pathComponents.contains(where: { $0.hasSuffix(".xcodeproj") || $0 == "build" || $0 == "DerivedData" }) {
                entries?.skipDescendants()
            }
        }
        throw Failure.noIconSet
    }

    /// Writes the icon and returns where it went.
    @discardableResult
    public static func install(picture: URL, projectRoot: URL) throws -> URL {
        let set = try iconSet(in: projectRoot)
        guard let source = CGImageSourceCreateWithURL(picture as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadable }
        let side = min(image.width, image.height)
        let square = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let cropped = image.cropping(to: square),
              let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.unreadable }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let output = set.appendingPathComponent(fileName)
        guard let icon = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.unwritable }
        CGImageDestinationAddImage(destination, icon, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable }
        try iconSetContents(filename: fileName).write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        return output
    }
}
