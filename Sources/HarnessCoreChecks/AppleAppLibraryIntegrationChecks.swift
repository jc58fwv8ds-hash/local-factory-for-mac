import Foundation
import HarnessCore

enum AppleAppLibraryIntegrationChecks {
    static func run(rootPath: String) async throws {
        let service = LocalAppleAppLibraryService()
        let source = AppleAppSource(
            projectID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            projectName: "Integration App",
            rootPath: rootPath
        )
        let apps = try await service.discoverApps(in: [source])
        try expect(
            apps.contains {
                !$0.displayName.isEmpty
                    && $0.configuration(for: .iPhone) != nil
                    && $0.iconData?.isEmpty == false
            },
            "Real Xcode app discovery must produce an iPhone tile with its source icon; found \(apps.map { "\($0.displayName)/\($0.supportedPlatforms)/\($0.iconData?.count ?? 0)" })"
        )
        print("✓ App library integration discovered \(apps.count) installable app(s)")
    }
}
