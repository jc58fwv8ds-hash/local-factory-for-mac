import Foundation
import HarnessCore
import Observation

/// 学習's face check (2026-11-10): a copy of a material video with the face of the user's own CG person on every frame and
/// its sound as it was, in the output folder. Runs face_lock.py and reports how far it has got.
///
/// One at a time, held here and not by the screen (2026-11-10, the user: 「顔の入替が2本？学習タブで指示出しした一本しか
/// ないはず」): the screen kept the running job in its own state, so after moving to another screen and back it showed
/// nothing running, and the same five-hour video was started a second time beside the first.
@MainActor @Observable
final class TrainingFaceCheck {
    static let shared = TrainingFaceCheck()

    /// The video being worked on, and how far it has got (「36 / 300 コマ」).
    private(set) var video: URL?
    private(set) var progress: String?
    /// What the last run ended with, shown under the materials.
    private(set) var result: String?
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// Starts unless one is running already; the result goes to the output folder and is shown in Finder.
    func start(face: URL, video: URL, done: @escaping @MainActor (URL) -> Void) {
        guard task == nil else { return }
        self.video = video
        progress = nil
        result = nil
        task = Task {
            let made = await Self.make(face: face, video: video) { line in self.progress = line }
            let stopped = Task.isCancelled
            task = nil
            self.video = nil
            progress = nil
            if let made {
                result = "できました: \(made.lastPathComponent)(出力フォルダ)"
                done(made)
            } else {
                result = stopped ? "止めました。" : "顔を入れ替えられませんでした。顔が写っていないか、顔のモデルがありません。"
            }
        }
    }

    func stop() { task?.cancel() }

    private static func make(face: URL, video: URL, progress report: @escaping @MainActor (String) -> Void) async -> URL? {
        let output = FaceLock.output(for: video, in: WorkspaceStore.imageFolder)
        let progress = output.appendingPathExtension("progress")
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if let line = FaceLock.progressLine(progress) { report(line) }
            }
        }
        defer { watcher.cancel(); try? FileManager.default.removeItem(at: progress) }
        let command = FaceLock.command(face: face, video: video, output: output, progress: progress)
        guard (try? await ImageGenerationService.run(command.program, command.arguments, limit: 24 * 3600)) != nil,
              FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        return output
    }
}
