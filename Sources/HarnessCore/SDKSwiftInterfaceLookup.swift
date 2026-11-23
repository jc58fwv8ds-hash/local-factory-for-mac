import Foundation

/// How Apple's Swift-only types are really declared, read from the SDK's `.swiftinterface` files, for a request or a step that
/// names one (2026-11-17: asked to move 14Translate to iOS 26's SpeechAnalyzer, the local model wrote
/// `SpeechAnalyzer(recognizer:)`, which does not exist; it was trained before the type and the headers SDKMemberLookup reads
/// do not have it, only the Swift interface does).
public final class SDKSwiftInterfaceLookup: @unchecked Sendable {
    public static let shared = SDKSwiftInterfaceLookup()
    private let lock = NSLock()
    private var interfaces: [(framework: String, text: String)]?
    private let sdkPath: () -> String?

    public init(sdkPath: @escaping () -> String? = { SDKSwiftInterfaceLookup.iosSDK() }) {
        self.sdkPath = sdkPath
    }

    /// Reference text for the SDK types named in `text`, or nil when none is found.
    public func reference(for text: String, maximumTypes: Int = 4) -> String? {
        let names = Self.candidateNames(text)
        guard !names.isEmpty else { return nil }
        let all = loadInterfaces()
        var blocks: [String] = []
        var frameworks: [String] = []
        for name in names where blocks.count < maximumTypes {
            for (framework, interface) in all {
                guard let block = Self.declaration(of: name, in: interface) else { continue }
                blocks.append("// \(framework)\n" + block)
                if !frameworks.contains(framework) { frameworks.append(framework) }
                break
            }
        }
        guard !blocks.isEmpty else { return nil }
        // The parts the named types are built from: types their declarations name, and the types that take on a protocol
        // they name (SpeechAnalyzer takes `[any SpeechModule]`; SpeechTranscriber is one).
        let shown = blocks.joined(separator: "\n")
        let related0 = frameworks.flatMap { framework in all.filter { $0.framework == framework } }
        for (framework, interface) in related0 where blocks.count < maximumTypes + 3 {
            for line in Self.typeLines(in: interface) where blocks.count < maximumTypes + 3 {
                guard let typeName = Self.typeName(line), !names.contains(typeName), !shown.contains("\(line)") else { continue }
                let protocols = line.components(separatedBy: ":").dropFirst().joined(separator: ",")
                let named = shown.range(of: "\\b" + typeName + "\\b", options: .regularExpression) != nil
                let conforms = protocols.split(separator: ",").contains { proto in
                    let p = proto.trimmingCharacters(in: .whitespaces)
                    return !p.isEmpty && p != "Sendable" && shown.contains("any " + p)
                }
                guard named || conforms, let block = Self.declaration(of: typeName, in: interface, maximumLines: 25) else { continue }
                blocks.append("// \(framework)\n" + block)
            }
        }
        // The other types of the same framework, by their first line, so the parts they are built from can be found.
        let related = frameworks.flatMap { framework in
            all.filter { $0.framework == framework }.flatMap { Self.typeLines(in: $0.text) }
        }
        return """
        参考(この Mac の Xcode の SDK にある本物の宣言。ここにない初期化や関数は存在しないので作らず、この形どおりに使うこと):
        \(blocks.joined(separator: "\n\n"))
        同じフレームワークの型:
        \(Array(NSOrderedSet(array: related)).compactMap { $0 as? String }.prefix(60).joined(separator: "\n"))
        """
    }

    /// Capitalised identifiers that look like type names (two or more words joined, such as SpeechAnalyzer).
    static func candidateNames(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\b([A-Z][a-z0-9]+(?:[A-Z][A-Za-z0-9]*)+)\b"#)
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }.filter { seen.insert($0).inserted }
    }

    /// The public declaration block of a type, cut to its member lines.
    static func declaration(of name: String, in interface: String, maximumLines: Int = 45) -> String? {
        let lines = interface.components(separatedBy: "\n")
        let pattern = #"^(@[\w() .,:*]+ )*(final )?(public |open )(final )?(class|struct|enum|actor|protocol) "# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
        guard let start = lines.firstIndex(where: { $0.range(of: pattern, options: .regularExpression) != nil }) else { return nil }
        var depth = 0
        var kept: [String] = []
        for line in lines[start...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let opening = trimmed.filter { $0 == "{" }.count, closing = trimmed.filter { $0 == "}" }.count
            if depth <= 1, !trimmed.hasPrefix("@available"), !trimmed.hasPrefix("#if"), !trimmed.hasPrefix("#endif"), !trimmed.isEmpty {
                kept.append(Self.plain(line))
            }
            depth += opening - closing
            if depth <= 0, !kept.isEmpty, opening + closing > 0 || kept.count > 1 { break }
            if kept.count >= maximumLines { kept.append("  …"); break }
        }
        return kept.joined(separator: "\n")
    }

    static func typeName(_ line: String) -> String? {
        guard let range = line.range(of: #"(class|struct|enum|actor|protocol) ([A-Z][A-Za-z0-9_]*)"#, options: .regularExpression) else { return nil }
        return line[range].split(separator: " ").last.map(String.init)
    }

    static func typeLines(in interface: String) -> [String] {
        interface.components(separatedBy: "\n").filter {
            $0.range(of: #"^(final )?(public |open )(final )?(class|struct|enum|actor|protocol) [A-Z]"#, options: .regularExpression) != nil
        }.map { Self.plain($0).replacingOccurrences(of: " {", with: "") }
    }

    /// Without the module prefixes the interface writes (`Speech::`, `Swift::`).
    static func plain(_ line: String) -> String {
        line.replacingOccurrences(of: #"\b[A-Z][A-Za-z_]*::"#, with: "", options: .regularExpression)
    }

    func sdkPathValue() -> String? { sdkPath() }

    func loadInterfaces() -> [(framework: String, text: String)] {
        lock.lock(); defer { lock.unlock() }
        if let interfaces { return interfaces }
        var found: [(String, String)] = []
        if let sdk = sdkPath() {
            let frameworks = URL(fileURLWithPath: sdk).appendingPathComponent("System/Library/Frameworks")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
            for framework in names where framework.hasSuffix(".framework") {
                let module = framework.replacingOccurrences(of: ".framework", with: "")
                let file = frameworks.appendingPathComponent("\(framework)/Modules/\(module).swiftmodule/arm64e-apple-ios.swiftinterface")
                if let text = try? String(contentsOf: file, encoding: .utf8) { found.append((module, text)) }
            }
        }
        interfaces = found
        return found
    }

    public static func iosSDK() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "iphoneos", "--show-sdk-path"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !path.isEmpty ? path : nil
    }
}
