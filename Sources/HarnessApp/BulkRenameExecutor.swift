import Foundation
import HarnessCore

/// Applies a checked RenamePlan inside one folder the user chose, and undoes it. Renames go through temporary names first,
/// so swaps (a → b, b → a) work; if any step fails, the steps already done are reversed. Nothing is deleted or overwritten.
enum BulkRenameExecutor {
    enum Failure: LocalizedError {
        case changed(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .changed(let name): "「\(name)」が見つからないか、すでに同じ名前のファイルがあります。下見のあとにフォルダが変わったようです。何も変更していません"
            case .failed(let detail): "名前を変えられませんでした。元に戻しました(\(detail))"
            }
        }
    }

    /// The folder's own files (not inside subfolders), without hidden ones.
    static func files(in folder: URL) throws -> [RenameFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                           options: [.skipsHiddenFiles]).compactMap { url in
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { return nil }
            return RenameFile(name: url.lastPathComponent, created: values.creationDate ?? .distantPast,
                              modified: values.contentModificationDate ?? .distantPast)
        }
    }

    static func apply(_ items: [RenamePlan.Item], in folder: URL) throws {
        let fm = FileManager.default
        let leaving = Set(items.map(\.from))
        for item in items {
            guard fm.fileExists(atPath: folder.appendingPathComponent(item.from).path) else { throw Failure.changed(item.from) }
            if !leaving.contains(item.to), fm.fileExists(atPath: folder.appendingPathComponent(item.to).path) {
                throw Failure.changed(item.to)
            }
        }
        let stamp = UUID().uuidString.prefix(8)
        var done: [(from: String, to: String)] = []
        do {
            for (index, item) in items.enumerated() {
                let temporary = ".lf-rename-\(stamp)-\(index)"
                try fm.moveItem(at: folder.appendingPathComponent(item.from), to: folder.appendingPathComponent(temporary))
                done.append((item.from, temporary))
            }
            for (index, item) in items.enumerated() {
                let temporary = ".lf-rename-\(stamp)-\(index)"
                try fm.moveItem(at: folder.appendingPathComponent(temporary), to: folder.appendingPathComponent(item.to))
                done[index] = (item.from, item.to)
            }
        } catch {
            for step in done.reversed() {
                try? fm.moveItem(at: folder.appendingPathComponent(step.to), to: folder.appendingPathComponent(step.from))
            }
            throw Failure.failed(error.localizedDescription)
        }
    }

    static func undo(_ items: [RenamePlan.Item], in folder: URL) throws {
        try apply(items.map { RenamePlan.Item(from: $0.to, to: $0.from) }, in: folder)
    }
}
