import Foundation
import HarnessCore

/// The light-job helper (2026-10-18, P1 experiment 1): a second Mac on Thunderbolt runs a small model (8B) for the
/// fixed-format jobs — Word and Excel edit instructions, aggregation SQL, PDF operations, rename rules — while this Mac's
/// 27B stays free for code changes. Measured: the 5 light jobs took 23.7 s on an M4 Air (35.7 s on the M5's 27B), and
/// running them there during a long answer cut the total from 111 s to 78 s.
///
/// The helper is reached only through SSH with a dedicated key (`~/.ssh/lfnode_ed25519`, host key stored as `lfnode-m4`):
/// its model server listens on the helper's 127.0.0.1 and this app forwards 127.0.0.1:18081 to it, so nothing is open on
/// the network. When the helper is off, asleep or unreachable, every job runs here as before.
actor HelperNode {
    struct Configuration: Equatable, Sendable {
        var enabled: Bool
        /// The helper's Bonjour host name; its Thunderbolt address is looked up on bridge0 (it changes on every restart).
        var hostName: String
        var user = "lfnode"
        var key = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/lfnode_ed25519").path
        var hostKeyAlias = "lfnode-m4"
        var modelPath = "lfnode/models/qwen3-8b.gguf"

        static let enabledKey = "helperNode.enabled", hostKey = "helperNode.hostName"
        static var saved: Configuration {
            Configuration(enabled: UserDefaults.standard.bool(forKey: enabledKey),
                          hostName: UserDefaults.standard.string(forKey: hostKey) ?? "")
        }
    }

    static let shared = HelperNode()
    static let localPort = 18081

    private var tunnel: Process?
    private var lastFailure: Date?
    /// Why the helper is not used, for the settings and the log.
    private(set) var problem: String?

    /// True when a light job can go to the helper now; starts the helper's model and the tunnel on first use.
    func ensureReady(_ configuration: Configuration = .saved) async -> Bool {
        guard configuration.enabled, !configuration.hostName.isEmpty,
              FileManager.default.fileExists(atPath: configuration.key) else { return false }
        if await healthy() { return true }
        // A helper that just failed is not retried for a minute (a light job must not wait on it each time).
        if let lastFailure, Date().timeIntervalSince(lastFailure) < 60 { return false }
        guard let address = Self.thunderboltAddress(of: configuration.hostName) else {
            lastFailure = Date(); problem = "Thunderbolt で「\(configuration.hostName)」が見つかりません"; return false
        }
        let ssh = ["-i", configuration.key, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=5",
                   "-o", "HostKeyAlias=\(configuration.hostKeyAlias)", "\(configuration.user)@\(address)"]
        // Start the model inside the helper (listening on its own 127.0.0.1) unless it already runs, kept awake while it runs.
        // By process name: `pgrep -f` would match this very command line, which contains the program's path.
        let start = """
        pgrep -x llama-server >/dev/null || (cd ~/lfnode && (DYLD_LIBRARY_PATH=$HOME/lfnode/bin bin/llama-server \
        -m $HOME/\(configuration.modelPath) --host 127.0.0.1 --port 8081 -c 8192 -ngl 999 -fa on > server8.log 2>&1 < /dev/null &); \
        sleep 2; P=$(pgrep -x llama-server | head -1); (caffeinate -s -w $P > /dev/null 2>&1 < /dev/null &))
        """
        let status = Self.run("/usr/bin/ssh", ssh + [start])
        guard status == 0 else { lastFailure = Date(); problem = "補助の Mac に入れません(ssh の終了コード \(status))"; return false }
        tunnel?.terminate()
        let forward = Process()
        forward.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        forward.arguments = ["-N", "-o", "ExitOnForwardFailure=yes", "-L", "127.0.0.1:\(Self.localPort):127.0.0.1:8081"] + ssh
        forward.standardOutput = FileHandle.nullDevice
        forward.standardError = FileHandle.nullDevice
        do { try forward.run() } catch { lastFailure = Date(); return false }
        tunnel = forward
        for _ in 0..<120 {   // loading the 8B takes about 25 s
            if await healthy() { lastFailure = nil; problem = nil; return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        lastFailure = Date(); problem = "補助の Mac のモデルが 60 秒以内に応答しません"
        return false
    }

    /// Closes the tunnel and stops the helper's model (called when the app quits: the helper is someone's Mac).
    func stop(_ configuration: Configuration = .saved) {
        tunnel?.terminate()
        tunnel = nil
        guard configuration.enabled, let address = Self.thunderboltAddress(of: configuration.hostName) else { return }
        _ = Self.run("/usr/bin/ssh", ["-i", configuration.key, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                                      "-o", "ConnectTimeout=3", "-o", "HostKeyAlias=\(configuration.hostKeyAlias)",
                                      "\(configuration.user)@\(address)", "pkill -x llama-server; pkill -x caffeinate"])
    }

    private func healthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.localPort)/health")!)
        request.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return false }
        return String(decoding: data, as: UTF8.self).contains("ok")
    }

    /// The helper's address on Thunderbolt Bridge: the ARP table first, else the link-local (169.254) addresses Bonjour
    /// gives for its name; the first one whose SSH port answers wins. (A Mac in stealth mode answers no ping, so a broadcast
    /// does not refill the ARP table: 2026-10-18.)
    static func thunderboltAddress(of hostName: String) -> String? {
        func output(_ tool: String, _ arguments: [String], seconds: Double? = nil) -> String {
            let pipe = Pipe(), process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            if let seconds {
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { if process.isRunning { process.terminate() } }
            }
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return text
        }
        let name = hostName.replacingOccurrences(of: ".local", with: "")
        var candidates = parseARP(output("/usr/sbin/arp", ["-a", "-i", "bridge0"]), hostName: name).map { [$0] } ?? []
        candidates += parseLinkLocal(output("/usr/bin/dns-sd", ["-G", "v4", name + ".local"], seconds: 2))
        for address in candidates where run("/usr/bin/nc", ["-z", "-G", "2", address, "22"]) == 0 { return address }
        return nil
    }

    /// The 169.254 addresses in `dns-sd -G v4` output, in order, without repeats.
    static func parseLinkLocal(_ text: String) -> [String] {
        var seen: [String] = []
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) where word.hasPrefix("169.254.") {
            if !seen.contains(String(word)) { seen.append(String(word)) }
        }
        return seen
    }

    /// "name.local (169.254.16.232) at … on bridge0" → the address of the line whose name is the host's.
    static func parseARP(_ text: String, hostName: String) -> String? {
        let wanted = hostName.lowercased().replacingOccurrences(of: ".local", with: "")
        for line in text.split(separator: "\n") where line.lowercased().hasPrefix(wanted + ".local ") || line.lowercased().hasPrefix(wanted + " ") {
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close else { continue }
            let address = String(line[line.index(after: open)..<close])
            if address.hasPrefix("169.254.") { return address }
        }
        return nil
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

extension WorkspaceStore {
    /// A fixed-format light job: on the helper's small model when it is ready, else on the selected model here.
    func lightJobEvents(_ request: InferenceRequest) async -> AsyncThrowingStream<String, Error> {
        if await HelperNode.shared.ensureReady() {
            let routed = InferenceRequest(runtime: .backburner, modelIdentifier: "helper:qwen3-8b", messages: request.messages,
                                          maximumOutputTokens: request.maximumOutputTokens, temperature: request.temperature)
            lastLightJobRoute = "補助の Mac"
            return await LocalInferenceService().events(for: routed)
        }
        lastLightJobRoute = "この Mac"
        return await inferenceProvider.events(for: request)
    }
}
