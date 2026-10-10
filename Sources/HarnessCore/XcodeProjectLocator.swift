import Foundation

public struct XcodeProjectContainer: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case workspace
        case project
    }

    public let kind: Kind
    public let relativePath: String

    public init(kind: Kind, relativePath: String) {
        self.kind = kind
        self.relativePath = relativePath
    }

    public var name: String {
        URL(fileURLWithPath: relativePath).lastPathComponent
    }

    var selectorArguments: [String] {
        [kind == .workspace ? "-workspace" : "-project", relativePath]
    }
}

public struct XcodeProjectLocator: Sendable {
    private let maximumEntries: Int

    public init(maximumEntries: Int = 1_000) {
        self.maximumEntries = max(1, maximumEntries)
    }

    public func locate(rootPath: String) -> XcodeProjectContainer? {
        let rootURL = URL(fileURLWithPath: rootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var candidates: [XcodeProjectContainer] = []
        var visitedEntries = 0
        for case let url as URL in enumerator {
            visitedEntries += 1
            if visitedEntries > maximumEntries { break }

            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            let loweredName = url.lastPathComponent.lowercased()
            if values?.isDirectory == true,
               SourceFilePolicy.excludedDirectoryNames.contains(loweredName) {
                enumerator.skipDescendants()
                continue
            }

            let kind: XcodeProjectContainer.Kind?
            switch url.pathExtension.lowercased() {
            case "xcworkspace": kind = .workspace
            case "xcodeproj": kind = .project
            default: kind = nil
            }
            guard let kind else { continue }
            candidates.append(
                XcodeProjectContainer(
                    kind: kind,
                    relativePath: SourceFilePolicy.relativePath(for: url, rootURL: rootURL)
                )
            )
            enumerator.skipDescendants()
        }

        return candidates.sorted(by: Self.isPreferred).first
    }

    private static func isPreferred(
        _ lhs: XcodeProjectContainer,
        _ rhs: XcodeProjectContainer
    ) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind == .workspace }
        let lhsDepth = lhs.relativePath.split(separator: "/").count
        let rhsDepth = rhs.relativePath.split(separator: "/").count
        if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
        return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }
}

public enum XcodeSchemeParser {
    public static func schemes(from output: String) -> [String] {
        metadata(from: output)?.schemes ?? []
    }

    public static func metadata(from output: String) -> XcodeProjectMetadata? {
        guard let end = output.lastIndex(of: "}") else { return nil }
        for start in output.indices.filter({ output[$0] == "{" }).suffix(256).reversed()
        where start < end {
            let data = Data(output[start...end].utf8)
            guard let response = try? JSONDecoder().decode(XcodeListResponse.self, from: data),
                  response.workspace != nil || response.project != nil else { continue }
            let container = response.workspace ?? response.project
            let schemes = Array(Set((container?.schemes ?? []).filter { !$0.isEmpty })).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            let targets = Array(Set((container?.targets ?? []).filter { !$0.isEmpty })).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            return XcodeProjectMetadata(schemes: schemes, targets: targets)
        }
        return nil
    }
}

public struct XcodeProjectMetadata: Equatable, Sendable {
    public let schemes: [String]
    public let targets: [String]

    public init(schemes: [String], targets: [String]) {
        self.schemes = schemes
        self.targets = targets
    }

    public var hasTestTarget: Bool {
        targets.contains {
            let value = $0.lowercased()
            return value.hasSuffix("tests") || value.hasSuffix("uitests")
        }
    }
}

private struct XcodeListResponse: Decodable {
    let project: XcodeListContainer?
    let workspace: XcodeListContainer?
}

private struct XcodeListContainer: Decodable {
    let schemes: [String]?
    let targets: [String]?
}
