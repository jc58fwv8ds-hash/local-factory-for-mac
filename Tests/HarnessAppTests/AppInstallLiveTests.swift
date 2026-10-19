import Foundation
import Testing
@testable import HarnessApp

/// A real install (2026-10-18): a chat request → Homebrew search → install → signature and notarization check.
/// HARNESS_INSTALL_LIVE=1. The app is not launched.
struct AppInstallLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_INSTALL_LIVE"] != nil))
    func installsASmallFreeAppAndChecksItsSignature() throws {
        let query = try #require(AppInstaller.query(from: "Itsycalをインストールして"))
        let candidates = try AppInstaller.search(query)
        let candidate = try #require(candidates.first)
        print("候補: \(candidates.map(\.token)) → \(candidate.token) \(candidate.version) / \(candidate.downloadHost) / sha256 \(candidate.hasChecksum) / \(candidate.appNames)")
        #expect(candidate.token == "itsycal")
        #expect(candidate.hasChecksum)
        _ = try AppInstaller.install(candidate.token)
        for name in candidate.appNames {
            let result = AppInstaller.verify(appAt: "/Applications/" + name)
            print("検証: \(name) 署名 \(result.signed) 公証 \(result.notarized) / \(result.detail)")
            #expect(result.signed)
            #expect(result.notarized)
        }
    }
}
