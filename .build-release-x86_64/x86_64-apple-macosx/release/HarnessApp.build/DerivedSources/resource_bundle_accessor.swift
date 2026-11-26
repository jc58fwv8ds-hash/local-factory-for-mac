import Foundation

extension Foundation.Bundle {
    static nonisolated let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("Harness_HarnessApp.bundle").path
        let buildPath = "/Users/yuta/Documents/Codex/2026-08-23/h/work/phase-b/work/public-repo/.build-release-x86_64/x86_64-apple-macosx/release/Harness_HarnessApp.bundle"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            // Users can write a function called fatalError themselves, we should be resilient against that.
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}