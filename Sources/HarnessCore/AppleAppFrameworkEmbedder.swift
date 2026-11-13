import Foundation

/// Adds a prebuilt framework (an .xcframework, such as llama.cpp's) to an iPhone app the scaffold made: copied into
/// 「Frameworks/」, linked, and embedded and signed in the app (2026-11-10: 14Translate needs llama.xcframework, a dynamic
/// framework, and the scaffold had no way to add one). Works on the one-object-per-line project files the scaffold
/// writes; anything else is refused rather than half edited.
public enum AppleAppFrameworkEmbedder {
    public enum Failure: LocalizedError, Equatable {
        case notAFramework, noProject, unsupportedProject, alreadyAdded
        public var errorDescription: String? {
            switch self {
            case .notAFramework: "xcframework を選んでください。"
            case .noProject: "Xcode のプロジェクトが見つかりません。"
            case .unsupportedProject: "このプロジェクトの形式には自動で部品を加えられません。Local Factory で作ったプロジェクトで使えます。"
            case .alreadyAdded: "この部品はすでに加えてあります。"
            }
        }
    }

    /// Copies and links the framework; returns where the copy is, relative to the project root.
    @discardableResult
    public static func add(_ framework: URL, to root: URL) throws -> String {
        let fileManager = FileManager.default
        guard framework.pathExtension == "xcframework" else { throw Failure.notAFramework }
        guard let project = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "xcodeproj" }) else { throw Failure.noProject }
        let file = project.appendingPathComponent("project.pbxproj")
        let relative = "Frameworks/" + framework.lastPathComponent
        let text = try edited(try String(contentsOf: file, encoding: .utf8), adding: relative)
        let destination = root.appendingPathComponent(relative)
        if framework.standardizedFileURL != destination.standardizedFileURL {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.copyItem(at: framework, to: destination)
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        return relative
    }

    /// The project text with the framework referenced, linked by the app target and embedded in it.
    static func edited(_ text: String, adding relative: String) throws -> String {
        guard !text.contains("path = \(relative);") else { throw Failure.alreadyAdded }
        var lines = text.components(separatedBy: "\n")
        func index(of id: String) -> Int? { lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(id + " ") } }
        func ids(_ key: String, in line: String) -> [String] {
            guard let range = line.range(of: "\(key) = (") else { return [] }
            let rest = line[range.upperBound...].prefix { $0 != ")" }
            return rest.split(separator: ",").compactMap { $0.split(separator: " ").first.map(String.init) }
        }
        func append(_ id: String, to key: String, at row: Int) {
            guard let range = lines[row].range(of: "\(key) = (") else { return }
            let close = lines[row][range.upperBound...].firstIndex(of: ")")!
            let empty = lines[row][range.upperBound..<close].trimmingCharacters(in: .whitespaces).isEmpty
            lines[row].insert(contentsOf: (empty ? "" : ", ") + id, at: close)
        }
        guard let appRow = lines.firstIndex(where: { $0.contains("isa = PBXNativeTarget;")
                && $0.contains("productType = \"com.apple.product-type.application\"") }),
              let projectRow = lines.firstIndex(where: { $0.contains("isa = PBXProject;") }),
              let mainGroup = lines[projectRow].range(of: "mainGroup = ").map({ String(lines[projectRow][$0.upperBound...].prefix(24)) }),
              let groupRow = index(of: mainGroup),
              let frameworksPhase = ids("buildPhases", in: lines[appRow]).first(where: { id in
                  index(of: id).map { lines[$0].contains("isa = PBXFrameworksBuildPhase;") } ?? false }),
              let frameworksRow = index(of: frameworksPhase)
        else { throw Failure.unsupportedProject }

        let name = (relative as NSString).lastPathComponent
        var counter = 1
        func newID() -> String {
            while true {
                let id = "K" + String(format: "%023d", counter); counter += 1
                if !text.contains(id) && !lines.contains(where: { $0.contains(id) }) { return id }
            }
        }
        let reference = newID(), link = newID(), embed = newID()
        append(reference, to: "children", at: groupRow)
        append(link, to: "files", at: frameworksRow)
        var embedPhase = ids("buildPhases", in: lines[appRow]).first { id in
            index(of: id).map { lines[$0].contains("dstSubfolderSpec = 10;") } ?? false }
        if let phase = embedPhase, let row = index(of: phase) {
            append(embed, to: "files", at: row)
        } else {
            let phase = newID(); embedPhase = phase
            append(phase, to: "buildPhases", at: appRow)
            insert("\t\t\(phase) /* Embed Frameworks */ = {isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 10; files = (\(embed)); name = \"Embed Frameworks\"; runOnlyForDeploymentPostprocessing = 0; };",
                   section: "PBXCopyFilesBuildPhase", into: &lines)
        }
        insert("\t\t\(link) /* \(name) in Frameworks */ = {isa = PBXBuildFile; fileRef = \(reference); };",
               section: "PBXBuildFile", into: &lines)
        insert("\t\t\(embed) /* \(name) in Embed Frameworks */ = {isa = PBXBuildFile; fileRef = \(reference); settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };",
               section: "PBXBuildFile", into: &lines)
        insert("\t\t\(reference) /* \(name) */ = {isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = \(relative); sourceTree = \"<group>\"; };",
               section: "PBXFileReference", into: &lines)
        return withRunpath(lines.joined(separator: "\n"))
    }

    /// The app finds embedded frameworks only where its run path points (2026-11-11: 14Translate quit at launch on the
    /// iPhone with 「Library not loaded: @rpath/llama.framework/llama」; the simulator had found it in the build folder).
    /// Adds @executable_path/Frameworks to the app target's configurations that lack a run path.
    static func withRunpath(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let appRow = lines.firstIndex(where: { $0.contains("isa = PBXNativeTarget;")
                && $0.contains("productType = \"com.apple.product-type.application\"") }),
              let listRange = lines[appRow].range(of: "buildConfigurationList = ") else { return text }
        let list = String(lines[appRow][listRange.upperBound...].prefix(24))
        guard let listRow = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(list + " ") }),
              let open = lines[listRow].range(of: "buildConfigurations = (") else { return text }
        let configurations = lines[listRow][open.upperBound...].prefix { $0 != ")" }
            .split(separator: ",").compactMap { $0.split(separator: " ").first.map(String.init) }
        for id in configurations {
            guard let row = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(id + " ") }),
                  !lines[row].contains("LD_RUNPATH_SEARCH_PATHS"),
                  let settings = lines[row].range(of: "buildSettings = {") else { continue }
            lines[row].insert(contentsOf: "LD_RUNPATH_SEARCH_PATHS = \"$(inherited) @executable_path/Frameworks\"; ", at: settings.upperBound)
        }
        return lines.joined(separator: "\n")
    }

    /// A project with embedded frameworks and no run path gets one. True when the file was changed.
    @discardableResult
    public static func repairRunpath(in root: URL) -> Bool {
        guard let project = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "xcodeproj" }) else { return false }
        let file = project.appendingPathComponent("project.pbxproj")
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains("dstSubfolderSpec = 10;") else { return false }
        let repaired = withRunpath(text)
        guard repaired != text else { return false }
        return (try? repaired.write(to: file, atomically: true, encoding: .utf8)) != nil
    }

    /// Into the section, made where it sorts among the others if the file has none yet.
    private static func insert(_ line: String, section: String, into lines: inout [String]) {
        if let end = lines.firstIndex(of: "/* End \(section) section */") { lines.insert(line, at: end); return }
        let begins = lines.enumerated().filter { $0.element.hasPrefix("/* Begin ") }
        let next = begins.first { $0.element.dropFirst(9).prefix { $0 != " " } > section[...] }?.offset
            ?? lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "};" } ?? lines.count
        lines.insert(contentsOf: ["/* Begin \(section) section */", line, "/* End \(section) section */", ""], at: next)
    }
}
