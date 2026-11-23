import Foundation

/// For 「type 'X.Options' has no member 'y'」 on an Objective-C option set or enum: what X.Options really has, and which
/// option set has 'y' (2026-11-17: asked to match glossary words without accents, the local model put `.diacriticInsensitive`
/// on `NSRegularExpression.Options` six times and gave up; it belongs to `NSString.CompareOptions`, which only the headers say).
public final class SDKOptionSetLookup: @unchecked Sendable {
    public static let shared = SDKOptionSetLookup()
    private let lock = NSLock()
    private var parsed: (sets: [String: [String]], classes: Set<String>)?
    private let sdkPath: () -> String?

    public init(sdkPath: @escaping () -> String? = { SDKSwiftInterfaceLookup.iosSDK() }) {
        self.sdkPath = sdkPath
    }

    public func hint(for message: String) -> String? {
        let plain = message.replacingOccurrences(of: #"' \(aka '[\w.]+'\) has no"#, with: "' has no", options: .regularExpression)
        guard let (rawType, member) = SDKMemberLookup.missingMember(in: plain) else { return nil }
        // 「type 'A.Options.ArrayLiteralElement' (aka 'A.Options')」: the aka is the real type.
        var type = rawType
        if let aka = message.range(of: #"\(aka '([\w.]+)'\)"#, options: .regularExpression) {
            type = String(message[aka]).replacingOccurrences(of: "(aka '", with: "").replacingOccurrences(of: "')", with: "")
        }
        type = type.replacingOccurrences(of: ".ArrayLiteralElement", with: "").replacingOccurrences(of: ".Element", with: "")
        let (sets, classes) = load()
        let objcName = type.replacingOccurrences(of: ".", with: "")
        var lines: [String] = []
        if let constants = sets[objcName] {
            lines.append("\(type) にあるのは: " + Self.swiftNames(constants).joined(separator: ", ") + "(SDK のヘッダーの \(objcName) より)")
        }
        let wanted = member.prefix(1).uppercased() + member.dropFirst()
        let owners = sets.filter { name, constants in name != objcName && constants.contains { $0.contains(wanted) } }.keys.sorted().prefix(3)
        if !owners.isEmpty {
            lines.append("「\(member)」があるのは: " + owners.map { Self.swiftName(of: $0, classes: classes) }.joined(separator: "、")
                + "。そちらの型を使う処理(たとえば文字列の比較や検索)で使ってください。")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// `NSStringCompareOptions` → `NSString.CompareOptions (NSStringCompareOptions)` when NSString is a class.
    static func swiftName(of objcName: String, classes: Set<String>) -> String {
        for split in stride(from: objcName.count - 1, to: 2, by: -1) {
            let head = String(objcName.prefix(split))
            if classes.contains(head) { return "\(head).\(objcName.dropFirst(split))(\(objcName))" }
        }
        return objcName
    }

    /// Constants without their shared prefix, lower-camel (`NSRegularExpressionCaseInsensitive` → `caseInsensitive`).
    static func swiftNames(_ constants: [String]) -> [String] {
        guard constants.count > 1, var prefix = constants.first else { return constants }
        for constant in constants.dropFirst() { while !constant.hasPrefix(prefix) { prefix.removeLast() } }
        // Keep whole words: cut back to a capital when the prefix ends inside one.
        func midWord(_ name: String) -> Bool { name.dropFirst(prefix.count).first.map { !$0.isUppercase } ?? false }
        while !prefix.isEmpty, constants.contains(where: midWord) { prefix.removeLast() }
        return constants.map { name in
            let rest = String(name.dropFirst(prefix.count))
            return rest.isEmpty ? name : rest.prefix(1).lowercased() + rest.dropFirst()
        }
    }

    /// NS_OPTIONS / NS_ENUM blocks of every framework header, and the Objective-C class names.
    static func parse(_ header: String) -> (sets: [String: [String]], classes: [String]) {
        var sets: [String: [String]] = [:]
        var classes: [String] = []
        var current: String?
        for raw in header.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@interface "), let name = line.dropFirst(11).split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).first {
                classes.append(String(name))
            }
            if let range = line.range(of: #"NS_(OPTIONS|ENUM|CLOSED_ENUM)\(\s*\w+\s*,\s*(\w+)\s*\)"#, options: .regularExpression) {
                current = line[range].components(separatedBy: ",").last?.trimmingCharacters(in: CharacterSet(charactersIn: " )"))
                if let current { sets[current] = [] }
                continue
            }
            guard let name = current else { continue }
            if line.hasPrefix("}") { current = nil; continue }
            if let constant = line.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).first,
               constant.hasPrefix(name.prefix(2)) { sets[name, default: []].append(String(constant)) }
        }
        return (sets, classes)
    }

    private func load() -> (sets: [String: [String]], classes: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        if let parsed { return parsed }
        var sets: [String: [String]] = [:]
        var classes = Set<String>()
        if let sdk = sdkPath() {
            let frameworks = URL(fileURLWithPath: sdk).appendingPathComponent("System/Library/Frameworks")
            for framework in (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? [] where framework.hasSuffix(".framework") {
                let headers = frameworks.appendingPathComponent(framework + "/Headers")
                for file in (try? FileManager.default.contentsOfDirectory(atPath: headers.path)) ?? [] where file.hasSuffix(".h") {
                    guard let text = try? String(contentsOf: headers.appendingPathComponent(file), encoding: .utf8),
                          text.contains("NS_") else { continue }
                    let found = Self.parse(text)
                    sets.merge(found.sets) { old, _ in old }
                    classes.formUnion(found.classes)
                }
            }
        }
        parsed = (sets, classes)
        return (sets, classes)
    }
}
