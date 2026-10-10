import Foundation
import HarnessExecution

enum DogfoodShadowProbe {
    enum Failure: Error { case invalidArguments, outputExists }

    static func run(arguments: [String]) throws {
        guard arguments.count == 4, arguments[1] == "--shadow-task" else {
            throw Failure.invalidArguments
        }
        let inputURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let outputURL = URL(fileURLWithPath: arguments[3]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw Failure.outputExists
        }
        let input = try JSONDecoder().decode(DogfoodShadowInput.self,
            from: Data(contentsOf: inputURL))
        let result = try DogfoodShadowPlanner.plan(input)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: outputURL, options: .atomic)
        print("DOGFOOD_SHADOW_RESULT: \(outputURL.path)")
    }
}
