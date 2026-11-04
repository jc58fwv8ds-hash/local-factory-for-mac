import SwiftUI

@main
struct HarnessRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                AgentScreen().tabItem { Label("エージェント", systemImage: "cursorarrow.motionlines") }
                ContentView().tabItem { Label("制作指示", systemImage: "hammer") }
            }
        }
    }
}