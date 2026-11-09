import Foundation
import HarnessCore

/// 学習's face check (2026-11-10): a copy of a material video with the face of the user's own CG person on every frame and
/// its sound as it was, in the output folder. Runs face_lock.py and reports how far it has got.
enum TrainingFaceCheck {
    @MainActor
    static func make(face: URL, video: URL, progress report: @escaping @MainActor (String) -> Void) async -> URL? {
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
        guard (try? await ImageGenerationService.run(command.program, command.arguments, limit: 4 * 3600)) != nil,
              FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        return output
    }
}
