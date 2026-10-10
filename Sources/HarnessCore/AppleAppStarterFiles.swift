import Foundation

enum AppleAppStarterFiles {
    static func make(for request: AppleAppScaffoldRequest) -> [String: String] {
        let product = request.productName
        let displayName = escaped(request.displayName)
        let bundleIdentifier = "\(request.organizationIdentifier).\(product.lowercased())"
        return [
            "\(product).xcodeproj/project.pbxproj": AppleAppProjectTemplate.make(
                productName: product,
                bundleIdentifier: bundleIdentifier
            ),
            "\(product).xcodeproj/xcshareddata/xcschemes/\(product).xcscheme": scheme(product),
            "\(product)/\(product)App.swift": appEntry(product),
            "\(product)/ContentView.swift": contentView,
            "\(product)/DesignSystem.swift": designSystem,
            "\(product)/RemoteProtocol.swift": remoteProtocol,
            "\(product)/RemoteSession.swift": remoteSession,
            "\(product)/Info.plist": infoPlist(displayName),
            "\(product)Tests/RemoteProtocolTests.swift": tests(product),
            "README.md": readme(product)
        ]
    }

    private static func appEntry(_ product: String) -> String {
        """
        import SwiftUI

        @main
        struct \(product)App: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }
        """
    }

    private static let contentView = """
    import SwiftUI

    struct ContentView: View {
        var body: some View {
            NavigationStack {
                ContentUnavailableView(
                    "Local Factoryを探しています",
                    systemImage: "iphone.radiowaves.left.and.right",
                    description: Text("この画面をLocal Factoryの制作指示で完成させます。")
                )
                .navigationTitle("Harness Remote")
            }
        }
    }
    """

    private static let designSystem = """
    import SwiftUI

    enum RemoteDesign {
        static let minimumTapTarget: CGFloat = 44
        static let cardCornerRadius: CGFloat = 18
    }
    """

    private static let remoteProtocol = """
    import Foundation

    struct RemoteInstructionRequest: Codable, Equatable {
        let version: Int
        let id: UUID
        let instruction: String
        let sentAt: Date
    }

    struct RemoteInstructionReceipt: Codable, Equatable {
        let version: Int
        let requestID: UUID
        let status: String
        let message: String
        let receivedAt: Date
    }
    """

    private static let remoteSession = """
    import Foundation
    import Observation

    @MainActor
    @Observable
    final class RemoteSession {
        var instruction = ""
        var statusMessage = "未接続"
        var pairingCode = ""
    }
    """

    private static func infoPlist(_ displayName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleDevelopmentRegion</key><string>$(DEVELOPMENT_LANGUAGE)</string>
        <key>CFBundleDisplayName</key><string>\(displayName)</string>
        <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
        <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
        <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
        <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
        <key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
        <key>LSRequiresIPhoneOS</key><true/>
        <key>UILaunchScreen</key><dict/>
        <key>UIApplicationSupportsIndirectInputEvents</key><true/>
        <key>NSLocalNetworkUsageDescription</key>
        <string>近くのMacで動作するHarnessへ制作指示を送るために使用します。</string>
        <key>NSBonjourServices</key><array><string>_harness-remote._tcp</string></array>
        </dict></plist>
        """
    }

    private static func tests(_ product: String) -> String {
        """
        import Foundation
        import Testing
        @testable import \(product)

        @Test func requestRoundTrip() throws {
            let request = RemoteInstructionRequest(
                version: 1,
                id: UUID(),
                instruction: "画面を確認して",
                sentAt: Date(timeIntervalSince1970: 1_000)
            )
            let data = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(RemoteInstructionRequest.self, from: data) == request)
        }
        """
    }

    private static func scheme(_ product: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion="2660" version="1.7">
          <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
            <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000001" BuildableName="\(product).app" BlueprintName="\(product)" ReferencedContainer="container:\(product).xcodeproj"/></BuildActionEntry></BuildActionEntries>
          </BuildAction>
          <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000002" BuildableName="\(product)Tests.xctest" BlueprintName="\(product)Tests" ReferencedContainer="container:\(product).xcodeproj"/></TestableReference></Testables></TestAction>
          <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000001" BuildableName="\(product).app" BlueprintName="\(product)" ReferencedContainer="container:\(product).xcodeproj"/></BuildableProductRunnable></LaunchAction>
          <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
          <AnalyzeAction buildConfiguration="Debug"/>
          <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
        </Scheme>
        """
    }

    private static func readme(_ product: String) -> String {
        """
        # \(product)

        Harnessが作成したiPhone用SwiftUI雛形です。ローカルネットワーク接続は明示操作後だけ開始し、ペアリングコードは保存しません。
        """
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
