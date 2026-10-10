import Foundation
import HarnessCore

enum HarnessAppEnvironment {
    static let fixtureWorkspaceKey = "HARNESS_GUI_FIXTURE_WORKSPACE"
    static let dogfoodCandidateBundleID = "local.harness.creation-studio.dogfood"

    static func supportFolderName(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        bundleIdentifier == dogfoodCandidateBundleID ? "HarnessCandidate" : "Harness"
    }

    static func workspaceRepository(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> WorkspaceRepository {
        guard let url = fixtureWorkspaceURL(
            environment: environment,
            temporaryDirectory: temporaryDirectory
        ) else {
            if supportFolderName() == "HarnessCandidate" {
                let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                    in: .userDomainMask).first ?? temporaryDirectory
                return WorkspaceRepository(fileURL: supportDirectory
                    .appendingPathComponent("HarnessCandidate", isDirectory: true)
                    .appendingPathComponent("workspace.json"))
            }
            return WorkspaceRepository()
        }
        return WorkspaceRepository(fileURL: url)
    }

    static func fixtureWorkspaceURL(
        environment: [String: String],
        temporaryDirectory: URL
    ) -> URL? {
        guard let rawPath = environment[fixtureWorkspaceKey],
              !rawPath.isEmpty,
              rawPath.hasPrefix("/") else { return nil }
        let temporaryRoot = temporaryDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = temporaryRoot.path.hasSuffix("/")
            ? temporaryRoot.path : temporaryRoot.path + "/"
        guard candidate.path.hasPrefix(rootPrefix),
              candidate.lastPathComponent == "workspace.json" else { return nil }
        return candidate
    }

    static func voiceCapsuleRootURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) -> URL {
        if let workspaceURL = fixtureWorkspaceURL(
            environment: environment,
            temporaryDirectory: temporaryDirectory
        ) {
            return workspaceURL.deletingLastPathComponent()
                .appendingPathComponent("VoiceCapsules", isDirectory: true)
        }
        let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? temporaryDirectory
        return supportDirectory
            .appendingPathComponent(supportFolderName(), isDirectory: true)
            .appendingPathComponent("VoiceCapsules", isDirectory: true)
    }

    static func voiceEngineRootURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) -> URL {
        if let workspaceURL = fixtureWorkspaceURL(
            environment: environment,
            temporaryDirectory: temporaryDirectory
        ) {
            return workspaceURL.deletingLastPathComponent()
                .appendingPathComponent("VoiceEngines", isDirectory: true)
        }
        let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? temporaryDirectory
        return supportDirectory
            .appendingPathComponent(supportFolderName(), isDirectory: true)
            .appendingPathComponent("VoiceEngines", isDirectory: true)
    }
}
