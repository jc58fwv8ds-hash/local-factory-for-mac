import Foundation

/// The names a type really has, read from the iOS SDK's headers, for a build error that says the type has no such
/// member (2026-11-10: fixing 「value of type 'AVAudioSessionPortDescription' has no member 'portDescription'」 the local
/// model swapped between 「port」 and 「portDescription」 four times; the real name is 「portName」, which no error said).
public final class SDKMemberLookup: @unchecked Sendable {
    public static let shared = SDKMemberLookup()
    private let lock = NSLock()
    private var cache: [String: [String]] = [:]
    private lazy var sdkPath: String? = Self.sdk()

    /// 「type 'X' has no member 'y'」 → X and y.
    public static func missingMember(in message: String) -> (type: String, member: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"type '([A-Za-z_][\w.]*)' has no (?:dynamic )?member '(\w+)'"#),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let type = Range(match.range(at: 1), in: message), let member = Range(match.range(at: 2), in: message)
        else { return nil }
        return (String(message[type]), String(message[member]))
    }

    /// One line for a repair instruction, or nil when the type is not found.
    public func hint(for message: String) -> String? {
        guard let (type, _) = Self.missingMember(in: message) else { return nil }
        let names = members(of: type)
        guard !names.isEmpty else { return nil }
        return "参考(SDK のヘッダーより): \(type) に実在する名前: " + names.prefix(30).joined(separator: ", ")
    }

    public func members(of type: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let known = cache[type] { return known }
        let found = sdkPath.map { Self.members(of: type, sdk: $0) } ?? []
        cache[type] = found
        return found
    }

    /// Properties and the first part of method names in the type's `@interface` blocks (the class and its categories).
    static func members(of type: String, sdk: String) -> [String] {
        let frameworks = URL(fileURLWithPath: sdk).appendingPathComponent("System/Library/Frameworks")
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: frameworks.path) else { return [] }
        var members: [String] = []
        for framework in names where framework.hasSuffix(".framework") {
            let headers = frameworks.appendingPathComponent(framework).appendingPathComponent("Headers")
            guard let files = try? fileManager.contentsOfDirectory(atPath: headers.path) else { continue }
            for file in files where file.hasSuffix(".h") {
                guard let text = try? String(contentsOf: headers.appendingPathComponent(file), encoding: .utf8),
                      text.contains("@interface \(type)") else { continue }
                members += Self.members(of: type, header: text)
            }
        }
        var seen = Set<String>()
        return members.filter { seen.insert($0).inserted }
    }

    static func members(of type: String, header: String) -> [String] {
        var result: [String] = []
        var inside = false
        for raw in header.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@interface \(type) ") || line.hasPrefix("@interface \(type):") || line == "@interface \(type)"
                || line.hasPrefix("@interface \(type)(") || line.hasPrefix("@interface \(type) (") { inside = true; continue }
            guard inside else { continue }
            if line.hasPrefix("@end") { inside = false; continue }
            if line.hasPrefix("@property") {
                var declaration = line
                for stop in [" API_", " NS_", " __", ";", " CF_", " UI_"] {
                    if let range = declaration.range(of: stop) { declaration = String(declaration[..<range.lowerBound]) }
                }
                if let name = declaration.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).last {
                    result.append(String(name))
                }
            } else if line.hasPrefix("- (") || line.hasPrefix("+ (") {
                if let close = line.firstIndex(of: ")") {
                    let name = line[line.index(after: close)...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    if !name.isEmpty { result.append(String(name) + "(…)") }
                }
            }
        }
        return result
    }

    private static func sdk() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "iphoneos", "--show-sdk-path"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !path.isEmpty ? path : nil
    }
}
