import Foundation

public struct BuildFailureDiagnostic: Identifiable, Equatable, Sendable {
    public var id: String {
        "\(validationKind.rawValue):\(relativePath):\(line ?? 0):\(column ?? 0):\(message)"
    }

    public let validationKind: ProjectValidationKind
    public let relativePath: String
    public let line: Int?
    public let column: Int?
    public let message: String

    public init(
        validationKind: ProjectValidationKind,
        relativePath: String,
        line: Int?,
        column: Int?,
        message: String
    ) {
        self.validationKind = validationKind
        self.relativePath = relativePath
        self.line = line
        self.column = column
        self.message = message
    }
}

public struct BuildFailureAnalysis: Equatable, Sendable {
    public let diagnostics: [BuildFailureDiagnostic]
    public let unresolvedErrorCount: Int
    public let failedKinds: [ProjectValidationKind]

    public init(
        diagnostics: [BuildFailureDiagnostic],
        unresolvedErrorCount: Int,
        failedKinds: [ProjectValidationKind]
    ) {
        self.diagnostics = diagnostics
        self.unresolvedErrorCount = unresolvedErrorCount
        self.failedKinds = failedKinds
    }

    public var primaryDiagnostic: BuildFailureDiagnostic? { diagnostics.first }

    public var repairPlan: BuildRepairPlan? {
        BuildRepairPlanner.plan(from: self)
    }

    public var repairInstruction: String? {
        repairPlan?.targets.first?.instruction
    }
}

public enum BuildFailureAnalyzer {
    private static let maximumDiagnostics = 12
    private static let maximumMessageLength = 800

    public static func analyze(
        report: ProjectValidationReport,
        rootPath: String
    ) -> BuildFailureAnalysis? {
        let failedChecks = report.checks.filter { !$0.succeeded }
        guard !failedChecks.isEmpty else { return nil }

        let rootURL = URL(fileURLWithPath: rootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var diagnostics: [BuildFailureDiagnostic] = []
        var seen = Set<String>()
        var unresolvedErrorCount = 0

        for check in failedChecks {
            for line in check.output.split(whereSeparator: \.isNewline) {
                guard let parsed = parseDiagnostic(String(line)) else { continue }
                guard let relativePath = safeRelativePath(
                        parsed.path,
                        rootURL: rootURL
                      ) else {
                    unresolvedErrorCount += 1
                    continue
                }
                let key = "\(relativePath):\(parsed.line ?? 0):\(parsed.column ?? 0):\(parsed.message)"
                guard seen.insert(key).inserted else { continue }
                guard diagnostics.count < maximumDiagnostics else {
                    unresolvedErrorCount += 1
                    continue
                }
                diagnostics.append(
                    BuildFailureDiagnostic(
                        validationKind: check.kind,
                        relativePath: relativePath,
                        line: parsed.line,
                        column: parsed.column,
                        message: String(parsed.message.prefix(maximumMessageLength))
                    )
                )
            }
        }

        // A type declared twice: the newest declaring file is the one to change (2026-11-10).
        diagnostics = RedeclarationRetarget.retarget(diagnostics, rootURL: rootURL)
        // A member another file needs and the type lacks: the type's file gets it (2026-11-11).
        diagnostics = MissingMemberRetarget.retarget(diagnostics, rootURL: rootURL)
        // Errors xcodebuild could not place (inside a macro such as #expect): the files of its 「The following build commands
        // failed: SwiftCompile … File.swift」 list get them (2026-11-12: JapaneseSpeakerTests' #expect errors named no file).
        if diagnostics.isEmpty {
            for check in failedChecks {
                diagnostics += CompileFailureFiles.diagnostics(output: check.output, rootURL: rootURL, kind: check.kind)
            }
        }
        // Tests that stopped on a dictionary with a key twice: the literal's file and line (2026-11-12: 14Translate's tests
        // crashed with 「Dictionary literal contains duplicate keys」 and no file could be named).
        if diagnostics.isEmpty, failedChecks.contains(where: { $0.output.contains("Dictionary literal contains duplicate keys") }) {
            diagnostics += DuplicateLiteralKeyCheck.diagnostics(rootURL: rootURL)
        }
        // No compile errors but failed tests: the tested files become the repair (2026-11-10).
        if diagnostics.isEmpty {
            for check in failedChecks where check.kind == .test || check.kind == .xcodeTest {
                diagnostics += TestFailureAnalyzer.diagnostics(output: check.output, rootURL: rootURL, kind: check.kind)
            }
        }
        return BuildFailureAnalysis(
            diagnostics: diagnostics,
            unresolvedErrorCount: unresolvedErrorCount,
            failedKinds: failedChecks.map(\.kind)
        )
    }

    private static func parseDiagnostic(_ line: String) -> ParsedDiagnostic? {
        let markers = [": fatal error: ", ": error: "]
        guard let marker = markers.compactMap({ marker -> (String, Range<String.Index>)? in
            line.range(of: marker).map { (marker, $0) }
        }).min(by: { $0.1.lowerBound < $1.1.lowerBound }) else { return nil }

        let location = String(line[..<marker.1.lowerBound])
        let message = String(line[marker.1.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        return parseLocation(location, message: message)
    }

    private static func parseLocation(
        _ location: String,
        message: String
    ) -> ParsedDiagnostic? {
        var components = location.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return nil }

        var column: Int?
        var line: Int?
        if let value = Int(components.last ?? "") {
            line = value
            components.removeLast()
        }
        if let value = Int(components.last ?? "") {
            column = line
            line = value
            components.removeLast()
        }
        guard line != nil else { return nil }
        let path = components.joined(separator: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return ParsedDiagnostic(path: path, line: line, column: column, message: message)
    }

    private static func safeRelativePath(
        _ path: String,
        rootURL: URL
    ) -> String? {
        let trimmed = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        let checkedComponents = path.hasPrefix("/") ? components.dropFirst() : components[...]
        guard !checkedComponents.isEmpty,
              !checkedComponents.contains(where: {
                $0 == "." || $0 == ".." || $0.isEmpty
              }) else {
            return nil
        }

        let candidate = path.hasPrefix("/")
            ? URL(fileURLWithPath: path).standardizedFileURL
            : rootURL.appendingPathComponent(trimmed).standardizedFileURL
        guard let values = try? candidate.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ), values.isRegularFile == true,
           values.isSymbolicLink != true,
           (values.fileSize ?? 0) <= ProjectFileEditor.maximumFileBytes else { return nil }

        let resolved = candidate.resolvingSymlinksInPath()
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard resolved.path.hasPrefix(rootPrefix),
              SourceFilePolicy.isAllowedFile(resolved),
              !SourceFilePolicy.isSensitiveFileName(resolved.lastPathComponent) else { return nil }
        return SourceFilePolicy.relativePath(for: resolved, rootURL: rootURL)
    }
}

private struct ParsedDiagnostic {
    let path: String
    let line: Int?
    let column: Int?
    let message: String
}
