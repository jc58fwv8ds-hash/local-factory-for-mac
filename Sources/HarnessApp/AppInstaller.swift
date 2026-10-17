import Foundation

/// Installing a Mac app from the chat (backlog #49, 2026-10-12, the user's request). Only Homebrew casks: each names its
/// download URL and version, and Homebrew checks the download against the cask's SHA-256 before installing. Nothing is
/// downloaded until the user picks a candidate on the card and presses インストールする; afterwards the app's code
/// signature and Apple notarization are checked and shown. No script from the web is ever run.
enum AppInstaller {
    struct Candidate: Equatable, Sendable, Identifiable {
        let token: String
        let name: String
        let summary: String
        let homepage: String
        let version: String
        let downloadHost: String
        /// false when the cask says `sha256 :no_check` (the download cannot be compared with a known hash).
        let hasChecksum: Bool
        let appNames: [String]
        let installed: Bool
        var id: String { token }
    }

    struct Verification: Equatable, Sendable {
        let app: String
        let signed: Bool
        let notarized: Bool
        let detail: String
    }

    enum Failure: LocalizedError, Equatable {
        case noHomebrew, notFound(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .noHomebrew: "アプリを入れるには Homebrew が必要です(https://brew.sh の手順で入ります)"
            case .notFound(let query): "「\(query)」に当たるアプリが Homebrew に見つかりませんでした。正式な名前で頼み直してください"
            case .failed(let detail): "インストールできませんでした: \(detail)"
            }
        }
    }

    static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    static var brew: String? { brewPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// "Firefoxをインストールして" → "Firefox". Only messages that say インストール count.
    static func query(from text: String) -> String? {
        // The message must end with the request itself (「インストール手順を README に書いて」 is not one).
        let ending = #"(を|って)?\s*(新しく)?インストール(して(ください|ほしい|欲しい)?|したい|お願い(します)?|できる|する)?[。！!？?]*\s*$"#
        guard let range = text.range(of: ending, options: .regularExpression) else { return nil }
        var name = String(text[..<range.lowerBound])
        name = name.replacingOccurrences(of: #"^\s*(アプリ(の)?|Mac\s*(に|へ)(は)?)\s*"#, with: "", options: .regularExpression)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "「」『』\"'、。")))
        return name.isEmpty || name.count > 60 || name.contains("\n") ? nil : name
    }

    /// Up to five casks for the query, an exact token or name first.
    static func search(_ query: String) throws -> [Candidate] {
        guard let brew else { throw Failure.noHomebrew }
        let words = query.lowercased().replacingOccurrences(of: " ", with: "-")
        let found = run(brew, ["search", "--cask", words]).output
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("==>") && !$0.isEmpty }
        let tokens = Array((found.filter { $0 == words } + found.filter { $0 != words }).prefix(5))
        guard !tokens.isEmpty else { throw Failure.notFound(query) }
        let info = run(brew, ["info", "--cask", "--json=v2"] + tokens)
        guard info.status == 0, let candidates = candidates(fromInfoJSON: Data(info.output.utf8)), !candidates.isEmpty else {
            throw Failure.notFound(query)
        }
        return candidates
    }

    static func candidates(fromInfoJSON data: Data) -> [Candidate]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = object["casks"] as? [[String: Any]] else { return nil }
        return casks.compactMap { cask in
            guard let token = cask["token"] as? String else { return nil }
            let apps = ((cask["artifacts"] as? [[String: Any]]) ?? []).compactMap { $0["app"] as? [Any] }.flatMap { $0 }
                .compactMap { $0 as? String }
            return Candidate(token: token, name: (cask["name"] as? [String])?.first ?? token,
                             summary: cask["desc"] as? String ?? "", homepage: cask["homepage"] as? String ?? "",
                             version: cask["version"] as? String ?? "",
                             downloadHost: URL(string: cask["url"] as? String ?? "")?.host ?? "",
                             hasChecksum: (cask["sha256"] as? String).map { $0 != "no_check" } ?? false,
                             appNames: apps, installed: cask["installed"] as? String != nil)
        }
    }

    /// Installs the cask; returns Homebrew's output.
    static func install(_ token: String) throws -> String {
        guard let brew else { throw Failure.noHomebrew }
        guard token.range(of: #"^[a-z0-9][a-z0-9@._+-]*$"#, options: .regularExpression) != nil else { throw Failure.failed(token) }
        let result = run(brew, ["install", "--cask", token], timeout: 1800)
        guard result.status == 0 else { throw Failure.failed(String(result.output.suffix(400))) }
        return result.output
    }

    /// The code signature (`codesign --verify --deep --strict`) and Gatekeeper's notarization check (`spctl -a`).
    static func verify(appAt path: String) -> Verification {
        let sign = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", path])
        let gate = run("/usr/sbin/spctl", ["-a", "-vv", "-t", "exec", path])
        let source = gate.output.split(separator: "\n").first { $0.contains("source=") }.map(String.init) ?? ""
        return Verification(app: path, signed: sign.status == 0, notarized: gate.status == 0 && source.contains("Notarized"),
                            detail: source.trimmingCharacters(in: .whitespaces))
    }

    private static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
