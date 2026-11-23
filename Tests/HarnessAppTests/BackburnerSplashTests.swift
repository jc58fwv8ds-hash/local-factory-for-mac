import Foundation
import Testing
@testable import HarnessApp

struct BackburnerSplashTests {
    @Test func identifierRoundTripsThroughModelPath() {
        let model = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models/Some-27B.gguf").path
        let identifier = BackburnerServer.identifier(for: model)
        #expect(identifier == "gguf:{home}/Models/Some-27B.gguf")
        #expect(BackburnerServer.modelPath(from: identifier) == model)
    }

    @Test func onlyA27BIsServedBySplash() {
        let small = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models/Writer-9B.gguf").path
        #expect(BackburnerServer.splashArguments(model: small) == nil)
    }
}
