import AppKit

@MainActor
final class HarnessApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if MainActor.assumeIsolated({ ComputerUseSelfTest.runIfRequested() }) { return }
        let current = NSRunningApplication.current
        guard let bundleIdentifier = current.bundleIdentifier else { return }
        let peers = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleIdentifier
                && $0.processIdentifier != current.processIdentifier
        }
        guard !peers.isEmpty else { return }

        let winner = (peers + [current]).sorted(by: ranksBefore).first
        guard winner?.processIdentifier == current.processIdentifier else {
            _ = winner?.activate(options: [.activateAllWindows])
            NSApplication.shared.terminate(nil)
            return
        }

        for peer in peers {
            _ = peer.terminate()
            let processIdentifier = peer.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let remaining = NSRunningApplication(
                    processIdentifier: processIdentifier
                ), !remaining.isTerminated else { return }
                _ = remaining.forceTerminate()
            }
        }
    }

    /// A Backburner server started by this App goes away with it (one started in Terminal is left running).
    func applicationWillTerminate(_ notification: Notification) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await BackburnerServer.shared.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }

    private func ranksBefore(
        _ lhs: NSRunningApplication,
        _ rhs: NSRunningApplication
    ) -> Bool {
        let lhsBuild = buildNumber(for: lhs)
        let rhsBuild = buildNumber(for: rhs)
        if lhsBuild != rhsBuild {
            return lhsBuild > rhsBuild
        }
        return lhs.processIdentifier < rhs.processIdentifier
    }

    private func buildNumber(for application: NSRunningApplication) -> Int {
        guard let url = application.bundleURL,
              let value = Bundle(url: url)?.object(
                forInfoDictionaryKey: "CFBundleVersion"
              ) as? String else {
            return 0
        }
        return Int(value) ?? 0
    }
}
