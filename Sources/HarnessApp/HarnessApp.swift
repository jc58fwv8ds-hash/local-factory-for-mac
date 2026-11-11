import HarnessCore
import SwiftUI

@main
struct HarnessApp: App {
    @NSApplicationDelegateAdaptor(HarnessApplicationDelegate.self) private var appDelegate
    @State private var store: WorkspaceStore
    @State private var appearance = AppearanceSettings()

    init() {
        _store = State(initialValue: WorkspaceStore(
            repository: HarnessAppEnvironment.workspaceRepository()
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .frame(minWidth: 1_120, minHeight: 700)
                .task {
                    SystemIntentClassifier.prewarm()
                    ModelCallLog.prune(LoggingInferenceProvider.folder)   // keep 14 days of the App's model-call log
                    store.fileOperationHooks.append(FileOperationJournal.standard)   // what the app did to files (#42)
                    ModelCallLog.prune(FileOperationJournal.standard.folder, keepingDays: 90)
                    ModelCallLog.prune(ComputerUseJournal.standard.folder, keepingDays: 90)
                    // Apps on a device whose free-account signature runs out by tomorrow: say so once at launch.
                    let expiring = DeviceInstallRecordStore.standard.load().filter { $0.needsReinstall() }
                    if !expiring.isEmpty {
                        store.presentNotice(expiring.compactMap { $0.expiryNote().map { "\($0)" } }
                            .enumerated().map { "\(expiring[$0.offset].appName)(\($0.element))" }.joined(separator: "、")
                            + "。端末がつながっていれば自動で入れ直します(つながっていなければ、つないだあとに入れ直します)。", kind: .information)
                    }
                    // Booked instructions (#43): checked once a minute while the app is open. Signatures that run out within a day
                    // are renewed at launch and then every hour (2026-11-11).
                    var minutes = 0
                    while !Task.isCancelled {
                        store.runDueScheduledInstructions()
                        if minutes % 60 == 0 { Task { await store.renewExpiringSignatures() } }
                        minutes += 1
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
                .font(.harness(.body))
                .environment(appearance)
                .tint(appearance.theme.accentColor)
                .preferredColorScheme(appearance.mode.colorScheme)
        }
        .defaultSize(width: 1_380, height: 860)
        .windowStyle(.hiddenTitleBar)
        // 「設定…」(⌘,): what is stopped and why, straight from the menu (2026-11-02, the user's request).
        Settings {
            ScrollView { ContentGuardSection().padding(24) }
                .frame(width: 620, height: 640)
                .font(.harness(.body))
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新規プロジェクト") {
                    store.isShowingNewProject = true
                }
                .keyboardShortcut("n")
            }
        }
    }
}
