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
                }
                .font(.harness(.body))
                .environment(appearance)
                .tint(appearance.theme.accentColor)
                .preferredColorScheme(appearance.mode.colorScheme)
        }
        .defaultSize(width: 1_380, height: 860)
        .windowStyle(.hiddenTitleBar)
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
