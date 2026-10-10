import Foundation
import Darwin
import HarnessExecution

enum BatchRecoveryCommand {
    enum Failure: Error { case arguments }
    static func run(_ arguments: [String]) async throws {
        guard arguments.count == 5 || arguments.count == 7 else { throw Failure.arguments }
        let direction = RecoverableFileBatch.Direction(rawValue: arguments[4])
        guard direction != nil || arguments[4] == "recover" else { throw Failure.arguments }
        let root = URL(fileURLWithPath: arguments[2])
        let directory = URL(fileURLWithPath: arguments[3])
        let killIndex: Int?
        if arguments.count == 7 {
            guard arguments[5] == "--test-kill-after-write", let index = Int(arguments[6]), index >= 0,
                  root.path.hasPrefix("/private/tmp/harness-batch-test-") else { throw Failure.arguments }
            killIndex = index
        } else { killIndex = nil }
        let result = try await RecoverableFileBatch(directory: directory).run(root: root, direction: direction) { index in
            if index == killIndex { kill(getpid(), SIGKILL) }
        }
        print("Batch recovery: \(result.phase), files: \(result.files.map(\.status))")
    }
}
