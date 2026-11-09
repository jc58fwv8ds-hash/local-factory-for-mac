import Foundation

/// The person's face on every frame of a video, its sound kept (2026-11-10): work/ImageEngines/face_lock.py, run with the
/// FaceSwap environment. Used by 学習 to check a material video with a face of the user's own CG person.
public enum FaceLock {
    public static func command(face: URL, video: URL, output: URL, progress: URL,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (program: URL, arguments: [String]) {
        (home.appendingPathComponent("Tools/FaceSwap/.venv/bin/python"),
         ["-I", home.appendingPathComponent("Tools/ImageEngines/face_lock.py").path, "--face", face.path, "--input", video.path,
          "--output", output.path, "--progress", progress.path])
    }

    /// 「<video>-顔入替-<time>.mp4」 in `folder`.
    public static func output(for video: URL, in folder: URL, at date: Date = Date()) -> URL {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        return folder.appendingPathComponent("\(video.deletingPathExtension().lastPathComponent)-顔入替-\(stamp.string(from: date)).mp4")
    }

    /// 「36 / 300 コマ」 from the progress file the script writes, or nil before it has written one.
    public static func progressLine(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
              let done = value["done"], let of = value["of"] else { return nil }
        return "\(done) / \(of) コマ"
    }
}
