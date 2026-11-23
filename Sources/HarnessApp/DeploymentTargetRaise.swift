import Foundation
import HarnessCore

/// 「'X' is only available in iOS 26 or newer」 while the person's iPhone runs a newer iOS: the project's minimum iOS is raised
/// instead of the code being rewritten around it (2026-11-17: 14Translate moved to SpeechAnalyzer; six repairs of the Swift
/// file could not fix what only the project's IPHONEOS_DEPLOYMENT_TARGET = 17.0 caused).
enum DeploymentTargetRaise {
    /// The highest iOS version the errors ask for.
    static func required(_ messages: [String]) -> String? {
        let versions = messages.compactMap { message -> String? in
            guard let range = message.range(of: #"only available in iOS ([0-9]+(\.[0-9]+)?) or newer"#, options: .regularExpression)
            else { return nil }
            return message[range].split(separator: " ").first { $0.first?.isNumber == true }.map(String.init)
        }
        return versions.max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Raises every lower IPHONEOS_DEPLOYMENT_TARGET in the project file. Returns the old value when it changed anything.
    static func raise(root: String, to version: String, phones: [String] = DevicePlatformNotes.connectedPhones()) -> String? {
        // Not past the iPhone the person uses.
        let phoneVersions = phones.compactMap { $0.split(separator: " ").dropFirst().first.map { String($0.prefix { $0.isNumber || $0 == "." }) } }
        if phoneVersions.contains(where: { $0.compare(version, options: .numeric) == .orderedAscending }) { return nil }
        let fm = FileManager.default
        guard let project = (try? fm.contentsOfDirectory(atPath: root))?.first(where: { $0.hasSuffix(".xcodeproj") }) else { return nil }
        let path = (root as NSString).appendingPathComponent(project + "/project.pbxproj")
        guard var text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let regex = try! NSRegularExpression(pattern: #"IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);"#)
        var old: String?
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let current = String(text[range])
            guard current.compare(version, options: .numeric) == .orderedAscending else { continue }
            old = old ?? current
            text.replaceSubrange(range, with: version)
        }
        guard let old, (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
        return old
    }
}
