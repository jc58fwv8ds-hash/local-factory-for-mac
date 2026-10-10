import AppKit
import Foundation
import HarnessCore

@MainActor
protocol XcodeProjectOpening {
    func openXcodeProject(rootPath: String) throws
}

enum XcodeProjectOpenError: LocalizedError {
    case projectUnavailable
    case openFailed

    var errorDescription: String? {
        switch self {
        case .projectUnavailable:
            "接続フォルダ内にXcodeプロジェクトが見つかりません。"
        case .openFailed:
            "Xcodeでプロジェクトを開けませんでした。Xcodeのインストールを確認してください。"
        }
    }
}

@MainActor
struct SystemXcodeProjectOpener: XcodeProjectOpening {
    private let locator = XcodeProjectLocator()

    func openXcodeProject(rootPath: String) throws {
        let rootURL = URL(fileURLWithPath: rootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard let container = locator.locate(rootPath: rootURL.path) else {
            throw XcodeProjectOpenError.projectUnavailable
        }
        let projectURL = rootURL
            .appendingPathComponent(container.relativePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard projectURL.path.hasPrefix(rootURL.path + "/"),
              NSWorkspace.shared.open(projectURL) else {
            throw XcodeProjectOpenError.openFailed
        }
    }
}
