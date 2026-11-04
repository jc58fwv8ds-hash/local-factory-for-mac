import AppKit
import Foundation
import Observation

/// The daily AI research news (2026-11-02): when it is made, whether and when it goes to YouTube, and with what privacy.
/// One file, ~/Library/Application Support/LocalFactory/DailyNews/settings.json, read by the scripts in
/// work/DailyNews too (run_daily.sh, youtube_upload.py); this screen writes it and rebuilds the launchd jobs.
struct DailyNewsSettings: Codable, Equatable {
    var enabled = true
    /// "HH:mm", when making the video starts.
    /// 2026-11-02: about ten minutes per paper (one to two hours in all) takes two to three hours to make.
    var productionTime = "04:00"
    var youtube = false
    /// Upload as soon as the video is made; otherwise at `uploadTime`.
    var uploadAfterProduction = true
    var uploadTime = "07:00"
    /// Always uploaded private (2026-11-02, the user: publishing is done by hand in YouTube Studio, and the API project
    /// stays unaudited, which allows private uploads only).
    var papers = 8
    /// Where run_daily.sh and the other scripts are: the copy the app keeps in Application Support (DailyNewsStore).
    var scriptsDirectory = ""
}

/// The launchd jobs for the settings, worked out without touching the system (tested), and putting them in place.
enum DailyNewsSchedule {
    static let produceLabel = "local.factory.dailynews.produce"
    static let uploadLabel = "local.factory.dailynews.upload"

    /// "05:30" → (5, 30); nil unless two-digit hour 0-23, ":", two-digit minute 0-59.
    static func time(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// The jobs the settings need: making the video every day when enabled, and a separate upload job only when the
    /// upload waits for its own time. A job missed while the Mac sleeps runs when it wakes (launchd).
    static func jobs(_ settings: DailyNewsSettings) -> [(label: String, plist: String)] {
        guard settings.enabled, !settings.scriptsDirectory.isEmpty, let make = time(settings.productionTime) else { return [] }
        let script = URL(fileURLWithPath: settings.scriptsDirectory).appendingPathComponent("run_daily.sh").path
        var result = [(produceLabel, plist(label: produceLabel, arguments: ["/bin/zsh", script, "produce"], hour: make.hour, minute: make.minute))]
        if settings.youtube, !settings.uploadAfterProduction, let up = time(settings.uploadTime) {
            result.append((uploadLabel, plist(label: uploadLabel, arguments: ["/bin/zsh", script, "upload"], hour: up.hour, minute: up.minute)))
        }
        return result
    }

    static func plist(label: String, arguments: [String], hour: Int, minute: Int) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(escape(label))</string>
          <key>ProgramArguments</key><array>\(arguments.map { "<string>\(escape($0))</string>" }.joined())</array>
          <key>StartCalendarInterval</key><dict><key>Hour</key><integer>\(hour)</integer><key>Minute</key><integer>\(minute)</integer></dict>
          <key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
        </dict>
        </plist>

        """
    }
}

@MainActor
@Observable
final class DailyNewsStore {
    var settings = DailyNewsSettings()
    var message = ""
    var log = ""
    /// The finished videos, newest first, and the link of those already on YouTube.
    var videos: [(date: String, url: String?)] = []
    /// The day being uploaded from this screen, and how far it is.
    var uploading: String?
    var uploadProgress = ""
    @ObservationIgnored private var uploadProcess: Process?
    @ObservationIgnored private var uploadStopped = false
    var youtubeAuthorized = false
    var clientSecretPresent = false
    var progress: DailyNewsProgress?

    @ObservationIgnored let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalFactory/DailyNews")
    private var settingsURL: URL { base.appendingPathComponent("settings.json") }
    private var agents: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents") }

    init() {
        if let data = try? Data(contentsOf: settingsURL), let saved = try? JSONDecoder().decode(DailyNewsSettings.self, from: data) {
            settings = saved
        }
        installScripts()
        refresh()
    }

    /// The scripts come inside the app (Resources/DailyNews, put there by scripts/package_release.sh from work/DailyNews)
    /// or, in a development build, from the checkout. They are copied to Application Support so the launchd jobs keep
    /// a path that does not move with the app.
    func installScripts() {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("DailyNews")
        let checkout = OrchestratedRunSettings().candidatePath.map { URL(fileURLWithPath: $0).appendingPathComponent("work/DailyNews") }
        guard let source = [bundled, checkout].compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("run_daily.sh").path)
        }) else { message = "ニュースの台本が見つかりません。アプリを作り直してください。"; return }
        let target = base.appendingPathComponent("scripts")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let staged = base.appendingPathComponent("scripts-new")
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: source, to: staged)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: target)
            }
            settings.scriptsDirectory = target.path
        } catch {
            message = "ニュースの台本を用意できませんでした: \(error.localizedDescription)"
        }
    }

    func refresh() {
        progress = DailyNewsProgress.read(base.appendingPathComponent("progress.json"))
        let keys = base.appendingPathComponent("youtube")
        youtubeAuthorized = FileManager.default.fileExists(atPath: keys.appendingPathComponent("token.json").path)
        clientSecretPresent = FileManager.default.fileExists(atPath: keys.appendingPathComponent("client_secret.json").path)
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LocalFactory-DailyNews.log")
        log = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").suffix(12).joined(separator: "\n")
        let done = (try? JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("uploaded.json")))) as? [String: [String: Any]] ?? [:]
        let movies = (try? FileManager.default.contentsOfDirectory(atPath: Self.moviesFolder.path)) ?? []
        // A day on YouTube stays listed after its file is tidied away from the Mac.
        videos = Array(Set(Self.videoDates(in: movies)).union(done.keys)).sorted(by: >).prefix(7)
            .map { (date: $0, url: done[$0]?["url"] as? String) }
    }

    /// Saves the settings and replaces the launchd jobs with the ones they need.
    func apply() {
        guard DailyNewsSchedule.time(settings.productionTime) != nil, DailyNewsSchedule.time(settings.uploadTime) != nil else {
            message = "時刻は「05:30」の形で入れてください。"; return
        }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: settingsURL, options: .atomic)
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            let jobs = DailyNewsSchedule.jobs(settings)
            for label in [DailyNewsSchedule.produceLabel, DailyNewsSchedule.uploadLabel] {
                _ = Self.launchctl(["bootout", "gui/\(getuid())/\(label)"])
                let file = agents.appendingPathComponent("\(label).plist")
                if let job = jobs.first(where: { $0.label == label }) {
                    try job.plist.write(to: file, atomically: true, encoding: .utf8)
                    guard Self.launchctl(["bootstrap", "gui/\(getuid())", file.path]) == 0 else {
                        message = "予約を登録できませんでした(\(label))。"; return
                    }
                } else if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            }
            message = settings.enabled
                ? "保存しました。毎日 \(settings.productionTime) に作ります" + (settings.youtube ? (settings.uploadAfterProduction ? "。完成したら YouTube に上げます。" : "。\(settings.uploadTime) に YouTube に上げます。") : "。")
                : "保存しました。毎日のニュースはオフです。"
        } catch {
            message = "保存できませんでした: \(error.localizedDescription)"
        }
    }

    /// Makes today's video now (the same job as the schedule).
    func produceNow() {
        message = Self.launchctl(["kickstart", "gui/\(getuid())/\(DailyNewsSchedule.produceLabel)"]) == 0
            ? "作り始めました。2〜3 時間かかります。" : "先に「保存して予約」を押してください。"
    }

    /// Stops today's job. launchd ends the rest of its process group with it, and the bar then says it stopped.
    func stopProduction() {
        message = Self.launchctl(["kill", "SIGKILL", "gui/\(getuid())/\(DailyNewsSchedule.produceLabel)"]) == 0
            ? "止めました。「今すぐ作る」で初めからやり直せます。" : "止められませんでした。動いていないようです。"
        refresh()
    }

    /// Opens the browser for the user to allow uploads to their channel (youtube_upload.py auth).
    func authorizeYouTube() {
        let python = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Tools/youtube-venv/bin/python").path
        let script = URL(fileURLWithPath: settings.scriptsDirectory).appendingPathComponent("youtube_upload.py").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script, "auth"]
        do { try process.run(); message = "ブラウザで Google アカウントを選び、許可してください。" }
        catch { message = "許可の画面を開けませんでした: \(error.localizedDescription)" }
    }

    func openKeysFolder() {
        let keys = base.appendingPathComponent("youtube")
        try? FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        NSWorkspace.shared.open(keys)
    }

    func stopUpload() {
        uploadStopped = true
        uploadProcess?.terminate()
    }

    static var moviesFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/AI研究ニュース") }

    func openMoviesFolder() { NSWorkspace.shared.open(Self.moviesFolder) }

    /// The days that have a finished video, newest first: 「AI研究ニュース-2026-11-04.mp4」, not trial cuts under other names.
    nonisolated static func videoDates(in fileNames: [String]) -> [String] {
        fileNames.compactMap { name -> String? in
            guard let match = name.wholeMatch(of: /AI研究ニュース-(\d{4}-\d{2}-\d{2})\.mp4/) else { return nil }
            return String(match.1)
        }.sorted(by: >)
    }

    /// Uploads one finished day now (2026-11-04, the user: with 「YouTube に上げる」 off when it was made, the app had no way
    /// to upload it afterwards). Private, like every upload; it does not depend on that setting.
    func upload(date: String) {
        guard uploading == nil else { return }
        uploadStopped = false
        let python = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Tools/youtube-venv/bin/python").path
        let script = URL(fileURLWithPath: settings.scriptsDirectory).appendingPathComponent("youtube_upload.py").path
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", script, "upload", "--date", date]
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            let line = text.split(whereSeparator: \.isNewline).last.map(String.init)
            guard let line else { return }
            Task { @MainActor in self?.uploadProgress = line }
        }
        process.terminationHandler = { [weak self] finished in
            let succeeded = finished.terminationStatus == 0
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.message = self.uploadStopped ? "\(date) のアップロードを止めました。" : succeeded ? "\(date) の動画を非公開で上げました。公開は YouTube Studio で行ってください。"
                    : "\(date) の動画を上げられませんでした: \(self.uploadProgress)"
                self.uploading = nil
                self.uploadProgress = ""
                self.refresh()
            }
        }
        do {
            uploading = date
            uploadProcess = process
            uploadProgress = "準備しています"
            try process.run()
        } catch {
            uploading = nil
            uploadProgress = ""
            message = "アップロードを始められませんでした: \(error.localizedDescription)"
        }
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus } catch { return -1 }
    }
}
