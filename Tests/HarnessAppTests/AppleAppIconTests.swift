import CoreGraphics
import Foundation
import HarnessCore
import ImageIO
import Testing
import UniformTypeIdentifiers

struct AppleAppIconTests {
    @Test func aNewIPhoneAppHasAnIconSetAndTheIconIsOpaque1024() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let result = try AppleAppScaffolder().create(.init(parentDirectoryPath: parent.path, productName: "IconProbe",
                                                           displayName: "Icon Probe"))
        #expect(result.createdRelativePaths.contains("IconProbe/Assets.xcassets/AppIcon.appiconset/Contents.json"))
        let pbx = try String(contentsOfFile: result.projectPath + "/project.pbxproj", encoding: .utf8)
        #expect(pbx.contains("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon"))

        // A 300×200 picture with transparency.
        let picture = parent.appendingPathComponent("in.png")
        let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let destination = CGImageDestinationCreateWithURL(picture as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))

        let icon = try AppleAppIcon.install(picture: picture, projectRoot: URL(fileURLWithPath: result.rootPath))
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(icon as CFURL, nil)!, 0, nil)!
        #expect(image.width == 1024 && image.height == 1024)
        #expect([.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo))
        let contents = try String(contentsOf: icon.deletingLastPathComponent().appendingPathComponent("Contents.json"), encoding: .utf8)
        #expect(contents.contains(AppleAppIcon.fileName))
    }
}
