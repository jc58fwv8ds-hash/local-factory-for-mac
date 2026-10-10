import Foundation

enum DogfoodCanaryBuildGate {
    enum Failure: Error { case buildFailed }

    static func build(project: URL, scheme: String, sdk: String, destination: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = ["-project", project.path, "-scheme", scheme,
            "-configuration", "Debug", "-sdk", sdk, "-destination", destination,
            "CODE_SIGNING_ALLOWED=NO", "build", "-quiet"]
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        process.environment = environment
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 120) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
            throw Failure.buildFailed
        }
        guard process.terminationStatus == 0 else { throw Failure.buildFailed }
    }
}
