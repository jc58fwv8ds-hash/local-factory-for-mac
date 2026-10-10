import Foundation

/// Bulk rename (file operations stage 2, 2026-10-09; docs/design/FILE-OPERATIONS.md). The model writes only a rule; this
/// expands it over every file, checks for collisions and invalid names, and the result is shown as a before → after table
/// before anything is renamed. A rule scales to thousands of files; a model writing each new name would not.
public struct RenameRule: Codable, Equatable, Sendable {
    /// Extensions to include, without the dot (empty: every file).
    public var extensions: [String]?
    /// Only names containing this text.
    public var nameContains: String?
    /// "name" (default), "created" or "modified": the order the numbers {n} follow.
    public var order: String?
    /// Optional regular expression applied to the old base name first; its result is {name}.
    public var find: String?
    public var replace: String?
    /// The new base name: {name}, {n} / {n:3} (number, zero-padded), {created:yyyyMMdd}, {modified:yyyy-MM-dd},
    /// {parent} (folder name). The extension is kept unless the template writes {ext} itself.
    public var template: String
    public var startNumber: Int?

    public init(extensions: [String]? = nil, nameContains: String? = nil, order: String? = nil, find: String? = nil,
                replace: String? = nil, template: String, startNumber: Int? = nil) {
        self.extensions = extensions; self.nameContains = nameContains; self.order = order
        self.find = find; self.replace = replace; self.template = template; self.startNumber = startNumber
    }
}

public struct RenameFile: Equatable, Sendable {
    public let name: String
    public let created: Date
    public let modified: Date

    public init(name: String, created: Date, modified: Date) {
        self.name = name; self.created = created; self.modified = modified
    }
}

public struct RenamePlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let from: String
        public let to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }
    /// Only the files whose name changes.
    public let items: [Item]
    public let matched: Int
    /// Reasons the plan cannot be applied (collisions, invalid names); empty when it can.
    public let problems: [String]

    public var canApply: Bool { problems.isEmpty && !items.isEmpty }
}

public enum BulkRename {
    public static let maximumFiles = 2_000

    public static func plan(_ rule: RenameRule, files: [RenameFile], folderName: String) -> RenamePlan {
        let extensions = Set((rule.extensions ?? []).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        var targets = files.filter { file in
            !file.name.hasPrefix(".")
                && (extensions.isEmpty || extensions.contains((file.name as NSString).pathExtension.lowercased()))
                && (rule.nameContains.map { file.name.contains($0) } ?? true)
        }
        switch rule.order {
        case "created": targets.sort { ($0.created, $0.name) < ($1.created, $1.name) }
        case "modified": targets.sort { ($0.modified, $0.name) < ($1.modified, $1.name) }
        default: targets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        var problems: [String] = []
        if targets.count > maximumFiles { problems.append("対象が \(targets.count) 件あります。\(maximumFiles) 件ずつに分けてください") }

        let start = rule.startNumber ?? 1
        var items: [RenamePlan.Item] = []
        for (index, file) in targets.enumerated() {
            let new = newName(for: file, number: start + index, rule: rule, folderName: folderName)
            if new != file.name { items.append(.init(from: file.name, to: new)) }
        }

        // Collisions: two files to one name, or a new name taken by a file this plan does not move away.
        let leaving = Set(items.map(\.from))
        let staying = Set(files.map(\.name)).subtracting(leaving)
        var seen: [String: String] = [:]
        for item in items {
            if item.to.isEmpty || item.to.contains("/") || item.to.contains(":") || item.to.hasPrefix(".") {
                problems.append("「\(item.from)」の新しい名前「\(item.to)」は使えません")
            } else if item.to.utf8.count > 255 {
                problems.append("「\(item.from)」の新しい名前が長すぎます")
            } else if let other = seen[item.to.lowercased()] {
                problems.append("「\(other)」と「\(item.from)」が同じ名前「\(item.to)」になります")
            } else if staying.contains(where: { $0.lowercased() == item.to.lowercased() }) {
                problems.append("「\(item.to)」はすでにあるファイルの名前です(「\(item.from)」)")
            }
            seen[item.to.lowercased()] = item.from
        }
        return RenamePlan(items: items, matched: targets.count, problems: Array(problems.prefix(10)))
    }

    static func newName(for file: RenameFile, number: Int, rule: RenameRule, folderName: String) -> String {
        let ext = (file.name as NSString).pathExtension
        var base = (file.name as NSString).deletingPathExtension
        if let find = rule.find, !find.isEmpty, let regex = try? NSRegularExpression(pattern: find) {
            base = regex.stringByReplacingMatches(in: base, range: NSRange(base.startIndex..., in: base),
                                                  withTemplate: rule.replace ?? "")
        }
        var result = rule.template
        let token = try! NSRegularExpression(pattern: #"\{(name|ext|n|created|modified|parent)(?::([^}]*))?\}"#)
        for match in token.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result), let keyRange = Range(match.range(at: 1), in: result) else { continue }
            let argument = Range(match.range(at: 2), in: result).map { String(result[$0]) }
            let value: String
            switch String(result[keyRange]) {
            case "name": value = base
            case "ext": value = ext
            case "n":
                let width = argument.flatMap(Int.init) ?? 0
                value = width > 0 ? String(format: "%0\(width)d", number) : String(number)
            case "created", "modified":
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = argument ?? "yyyyMMdd"
                value = formatter.string(from: result[keyRange] == "created" ? file.created : file.modified)
            default: value = folderName
            }
            result.replaceSubrange(range, with: value)
        }
        let keepsExtension = !rule.template.contains("{ext}") && !ext.isEmpty
        return result.trimmingCharacters(in: .whitespaces) + (keepsExtension ? "." + ext : "")
    }
}
