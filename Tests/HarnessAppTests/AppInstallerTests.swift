import Foundation
import Testing
@testable import HarnessApp

/// Backlog #49 (2026-10-12): 「◯◯をインストールして」 → Homebrew cask candidates; nothing is installed without the button.
struct AppInstallerTests {
    @Test(arguments: [("Firefoxをインストールして", "Firefox"), ("「Visual Studio Code」をインストールしてください", "Visual Studio Code"),
                      ("Mac に Rectangle をインストールしたい", "Rectangle"), ("ファイアフォックスってインストールできる？", "ファイアフォックス")])
    func theAppNameIsReadFromTheRequest(text: String, name: String) {
        #expect(AppInstaller.query(from: text) == name)
    }

    @Test(arguments: ["Firefoxを入れて", "インストール手順を README に書いて", "インストールの画面を作って", "今日はいい天気", "インストールして"])
    func otherMessagesAreNotInstallRequests(text: String) {
        #expect(AppInstaller.query(from: text) == nil)
    }

    @Test func caskInformationBecomesCandidatesWithTheirSource() throws {
        let json = #"{"casks":[{"token":"firefox","name":["Mozilla Firefox"],"desc":"Web browser","homepage":"https://www.mozilla.org/firefox/","version":"157.0.1","url":"https://download-installer.cdn.mozilla.net/pub/firefox/x.dmg","sha256":"9ad3","installed":null,"artifacts":[{"app":["Firefox.app"],"target":"/Applications/Firefox.app"},{"zap":[]}]},{"token":"nightly-tool","name":["Tool"],"desc":null,"homepage":"https://example.org","version":"latest","url":"https://example.org/t.zip","sha256":"no_check","installed":"1.0","artifacts":[]}]}"#
        let candidates = try #require(AppInstaller.candidates(fromInfoJSON: Data(json.utf8)))
        #expect(candidates.map(\.token) == ["firefox", "nightly-tool"])
        #expect(candidates[0].downloadHost == "download-installer.cdn.mozilla.net" && candidates[0].appNames == ["Firefox.app"])
        #expect(candidates[0].hasChecksum && !candidates[0].installed)
        #expect(!candidates[1].hasChecksum && candidates[1].installed)
    }
}
