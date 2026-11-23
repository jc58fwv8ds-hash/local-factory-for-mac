import Foundation

/// Which iOS the person's iPhone runs, which SDK this Mac builds with, and which iOS the project still asks for, given
/// with every request for an iPhone project (2026-11-16, the user: 「最新の iOS 27 が入ってるんだぞ？」「Xcode 見ててそれも
/// 分からないのか？」: 14Translate stayed on the old one-phrase speech recognizer of iOS 10 because its deployment target
/// said 17.0, though the iPhone ran 27.2.1 and the SDK was 27.2).
enum DevicePlatformNotes {
    static func notes(root: String) -> String? {
        guard let target = deploymentTarget(root: root) else { return nil }
        let sdk = run("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-version"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let phones = connectedPhones()
        var lines = ["このアプリが動く環境(Mac と iPhone から読んだもの):"]
        if !phones.isEmpty { lines.append("・つないでいる iPhone: " + phones.joined(separator: "、")) }
        if let sdk, !sdk.isEmpty { lines.append("・この Mac の Xcode で使える iOS の SDK: \(sdk)") }
        lines.append("・プロジェクトの最低 iOS(IPHONEOS_DEPLOYMENT_TARGET): \(target)")
        lines.append("使う人の iPhone で動く新しい iOS の仕組みのほうが頼まれたことに合うなら、古い仕組みに合わせず新しい仕組みを使ってください"
            + "(必要なら最低 iOS を iPhone の版まで上げてかまいません)。端末によって使えない仕組みは、使えるかを確かめてから使ってください。")
        return lines.joined(separator: "\n")
    }

    static func deploymentTarget(root: String) -> String? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: root),
              let project = items.first(where: { $0.hasSuffix(".xcodeproj") }),
              let text = try? String(contentsOfFile: (root as NSString).appendingPathComponent(project + "/project.pbxproj"), encoding: .utf8),
              let range = text.range(of: #"IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+"#, options: .regularExpression) else { return nil }
        return String(text[range].split(separator: "=").last ?? "").trimmingCharacters(in: .whitespaces)
    }

    static func connectedPhones() -> [String] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("harness-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = run("/usr/bin/xcrun", ["devicectl", "list", "devices", "--json-output", file.path], timeout: 8)
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { device in
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            guard hardware["platform"] as? String == "iOS", hardware["reality"] as? String == "physical",
                  let version = properties["osVersionNumber"] as? String else { return nil }
            return "iOS \(version)(\(hardware["productType"] as? String ?? "iPhone"))"
        }
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return nil }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
