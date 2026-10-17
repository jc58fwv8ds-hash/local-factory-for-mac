import AppKit
import Foundation
import HarnessCore

/// A test run of Computer Use stage 1 started from the command line (2026-10-18), so the developer can try it on the real
/// Mac without clicking through the app: `open -a "Local Factory" --args --computer-use-selftest "<goal>"`. It runs the
/// agent once with Backburner, refuses every step that needs approval (a test never sends, buys or deletes), writes each
/// step to ~/Library/Application Support/Harness/computer-use-selftest.log and quits.
@MainActor
enum ComputerUseSelfTest {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--computer-use-selftest"), index + 1 < arguments.count else { return false }
        let goal = arguments[index + 1]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let log = support.appendingPathComponent("Harness/computer-use-selftest.log")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let write: @Sendable (String) -> Void = { line in
            let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
            if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); handle.write(Data(stamped.utf8)); try? handle.close() }
            else { try? stamped.write(to: log, atomically: true, encoding: .utf8) }
        }
        write("開始: \(goal) / アクセシビリティの許可: \(AXIsProcessTrusted() ? "あり" : "なし")")
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            write("終了: 許可がないため止めました(システム設定で Local Factory を許可してください)")
            NSApp.terminate(nil)
            return true
        }
        let controller = AccessibilityComputerUse()
        if let at = arguments.firstIndex(of: "--target"), at + 1 < arguments.count,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == arguments[at + 1] }) {
            controller.focus(on: app)
            write("操作の対象: \(arguments[at + 1])")
        }
        let provider = LocalInferenceService()
        let model = ModelSelection(identifier: "qwen3.8-27b-iq4xs", displayName: "Backburner", runtime: .backburner)
        Task {
            let outcome = await ComputerUseAgent.run(
                goal: goal, controller: controller,
                decide: { messages, screenshot in
                    var reply = ""
                    let request = InferenceRequest(runtime: model.runtime, modelIdentifier: model.identifier, messages: messages,
                                                   maximumOutputTokens: 400,
                                                   images: await ComputerUseScreenshot.inferenceImages(screenshot), temperature: 0)
                    for try await piece in await provider.events(for: request) { reply += piece }
                    write("モデル: \(reply.replacingOccurrences(of: "\n", with: " ").prefix(300))")
                    return reply
                },
                approve: { action, reason in
                    write("確認が必要なので行わない: \(action)(\(reason))")
                    return false
                },
                onStep: { step in write("一手: \(step.action) → \(step.result)") })
            write("終了: \(outcome)")
            NSApp.terminate(nil)
        }
        return true
    }
}
