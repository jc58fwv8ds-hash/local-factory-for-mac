import Foundation
import HarnessCore

/// 「iPhone に入れて」 in the code chat (2026-11-11, the user: 「Xcode でのサインインや、iPhone 側で開発者を信頼する操作に
/// ついては君に頼んだらいつもやってくれているからファクトリーにも頼みたい」): the app is built with the free signing,
/// installed on the connected iPhone and opened, and each step is written back into the chat in plain words. What only the
/// person can do on the iPhone itself (unlocking it, Developer Mode, trusting the developer) is asked for plainly.
extension WorkspaceStore {
    func submitDeviceRun() -> Bool {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard workspaceMode == .code, CodeChatIntent.asksForDevice(text),
              let record = library.selectedRecord, let root = record.sourceLocation else { return false }
        let id = record.id
        library.updateSelectedProject { $0.conversation.append(ConversationMessage(role: .user, content: text, origin: .user)) }
        instruction = ""
        note("iPhone に入れます。つながっている iPhone を探しています。", to: id)
        let provider = physicalDeviceProvider
        Task { [weak self] in
            await self?.runOnDevice(root: root, projectID: id, provider: provider)
        }
        return true
    }

    private func runOnDevice(root: String, projectID: UUID, provider: any PhysicalDeviceProviding) async {
        do {
            let devices = try await provider.listDevices().filter { $0.platform == .iPhone }
            guard let device = devices.first(where: \.isPaired) ?? devices.first else {
                return note("iPhone が見つかりませんでした。ケーブルでこの Mac につなぐか、同じ Wi-Fi で近くに置き、ロックを外してから、もう一度「iPhone に入れて」と書いてください。", to: projectID)
            }
            if AppleAppFrameworkEmbedder.repairRunpath(in: URL(fileURLWithPath: root)) {
                note("加えた部品をアプリが iPhone で見つけられるよう、プロジェクトに読み込み先の設定を足しました。", to: projectID)
            }
            let readiness = try await provider.inspect(rootPath: root, device: device)
            guard readiness.canRun else {
                let asks = readiness.requirements.map(DeviceChatWords.ask)
                let summary = asks.isEmpty ? (readiness.preparation?.summary() ?? "iPhone の準備がまだ確かめられませんでした。") : ""
                return note("\(device.name) に入れる前に、次のことが要ります。\n" + (asks + [summary]).filter { !$0.isEmpty }.map { "・" + $0 }.joined(separator: "\n")
                            + "\n済んだら、もう一度「iPhone に入れて」と書いてください。", to: projectID)
            }
            let report = try await provider.run(rootPath: root, device: device) { [weak self] stage in
                await self?.note(stage.displayName, to: projectID)
            }
            let record = DeviceInstallRecord(appKey: root, appName: report.productName, deviceIdentifier: report.deviceIdentifier,
                                             deviceName: report.deviceName, profile: report.profile)
            if report.profile != nil { DeviceInstallRecordStore.standard.record(record) }
            note("\(report.productName) を \(report.deviceName) に入れて、開きました。" + (record.expiryNote().map { "(\($0))" } ?? ""), to: projectID)
        } catch {
            note(DeviceChatWords.failure(error.localizedDescription), to: projectID)
        }
    }

    /// The autopilot's report, written into the chat.
    func autopilotReported(_ message: String) {
        appendAssistantNote(message)
    }

    /// A run ended. The next waiting request of the batch starts; when none waits, the batch is summed up and an app
    /// already on an iPhone goes back on it once (2026-11-11: after a fix the user had to ask 「iPhone に入れて」 again;
    /// 2026-11-12: a message with several things to fix runs as several requests, one after another).
    func autopilotEnded(good: Bool, closed: Bool) {
        guard let record = library.selectedRecord, let root = record.sourceLocation else { return }
        let id = record.id
        if closed {
            if AutopilotRequests.shared.hasWaiting(id) {
                note("今のプロジェクトのままでは先に進めないので、残りの依頼は止めました。直してから「続けて」と書けば、残りを順に進めます。", to: id)
            }
            return AutopilotRequests.shared.cancelWaiting(projectID: id)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))   // the closing screen first, then the next one opens
            guard let self else { return }
            let waiting = AutopilotRequests.shared.hasWaiting(id)
            let tally = AutopilotRequests.shared.ended(projectID: id, good: good)
            if waiting { return self.note("次の依頼に進みます。", to: id) }
            if let tally, tally.total > 1 { self.note("分けた依頼 \(tally.total) 件のうち、\(tally.good) 件ができました。", to: id) }
            let anyGood = tally.map { $0.good > 0 } ?? good
            guard anyGood, DeviceInstallRecordStore.standard.load().contains(where: { $0.appKey == root }) else { return }
            self.note("直した版を iPhone に入れ直します。", to: id)
            await self.runOnDevice(root: root, projectID: id, provider: self.physicalDeviceProvider)
        }
    }

    /// The newest crash reports of this project's app on the iPhone it was last put on, as advice for the repair, with the
    /// file of the type it crashed in. Nil when the app was never put on an iPhone or left no report.
    func crashContext(root: String) async -> (detail: String, summary: String)? {
        guard let install = DeviceInstallRecordStore.standard.load().filter({ $0.appKey == root }).max(by: { $0.installedAt < $1.installedAt })
        else { return nil }
        let texts = await DeviceCrashLogs.latest(appName: install.appName, deviceIdentifier: install.deviceIdentifier,
                                                 since: install.installedAt.addingTimeInterval(-60))
        var seen = Set<[String]>()
        let reports = texts.compactMap { DeviceCrashReport.parse($0, appName: install.appName) }.filter { seen.insert($0.appFrames).inserted }
        guard !reports.isEmpty else { return nil }
        let rootURL = URL(fileURLWithPath: root)
        let detail = reports.prefix(2).map { report in
            let file = report.typeName.flatMap { DeviceCrashFile.declaring($0, under: rootURL) }
            return report.advice + (file.map { "\n直すファイル: \($0)" } ?? "")
        }.joined(separator: "\n\n")
        return (detail, reports[0].plainSummary)
    }

    func noteTrouble(crash: Bool, summary: String?, hints: [String], projectID: UUID) {
        let found = NotWorkingHints.plain(hints).map { "・" + $0 }
        var lines = [summary.map { "わかったこと: " + $0 } ?? (crash ? "iPhone からは、止まった原因の手がかりが見つかりませんでした。" : nil)].compactMap { $0 }
        if !found.isEmpty { lines.append((summary == nil ? "わかったこと:" : "ほかにも:") + "\n" + found.joined(separator: "\n")) }
        if lines.isEmpty { lines.append("コードからは原因の手がかりが見つかりませんでした。") }
        note(lines.joined(separator: "\n") + "\nこれをもとに直します。", to: projectID)
    }

    func note(_ text: String, to projectID: UUID) {
        library.updateProject(projectID) { $0.conversation.append(ConversationMessage(role: .assistant, content: text, origin: .localModel)) }
        persist()
    }
}

/// What the person is asked to do, in plain words.
enum DeviceChatWords {
    static func ask(_ requirement: PhysicalDeviceSetupRequirement) -> String {
        switch requirement {
        case .unlockDevice, .verifyDeviceState: "iPhone のロックを外して、画面をつけたままにしてください。"
        case .pairDevice: "iPhone に「このコンピュータを信頼しますか?」と出たら「信頼」を押してください。"
        case .enableDeveloperMode: "iPhone の「設定」→「プライバシーとセキュリティ」→「デベロッパモード」をオンにしてください(iPhone が再起動します)。"
        case .selectDevelopmentTeam: "Xcode に Apple ID でサインインしてください(Xcode の「設定」→「アカウント」)。無料で使えます。"
        case .selectAutomaticSigning, .configureBundleIdentifier, .selectIOSApplication:
            "プロジェクトの「\(requirement.title)」を Factory が決められませんでした。"
        }
    }

    /// The error of a failed run, with what to do when it is the iPhone's own step.
    static func failure(_ message: String) -> String {
        let lowered = message.lowercased()
        if ["not been explicitly trusted", "untrusted", "信頼"].contains(where: lowered.contains) {
            return "アプリは入りましたが、iPhone がまだこの開発者を信頼していないため開けませんでした。iPhone の「設定」→「一般」→「VPN とデバイス管理」→「デベロッパApp」の Apple Development を開き、「信頼」を押してから、もう一度「iPhone に入れて」と書いてください。"
        }
        if lowered.contains("iphone がロックされています") {
            return "iPhone がロックされていて入れられませんでした。ロックを外して、画面をつけたまま、もう一度「iPhone に入れて」と書いてください。"
        }
        return "iPhone に入れられませんでした。理由: " + message
    }
}
