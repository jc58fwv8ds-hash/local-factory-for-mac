import Foundation

/// After an Office edit (2026-10-12 review: "complex documents are not shown to survive"): every part of the package
/// except the ones the edit rewrote must be byte-for-byte the same in the new file, compared by the CRC-32 that
/// `unzip -v` lists. Shapes, text boxes, images, styles, headers, charts and anything else this app does not touch can
/// therefore not be changed by it; a difference stops the edit before the new file is kept.
enum OfficePackageCheck {
    enum Failure: LocalizedError, Equatable {
        case changed([String]), unreadable
        var errorDescription: String? {
            switch self {
            case .changed(let parts): "編集していない部分が変わってしまうため中止しました(\(parts.prefix(3).joined(separator: "、")))"
            case .unreadable: "書き出したファイルを確かめられませんでした"
            }
        }
    }

    /// Part name → CRC-32 of a zip package.
    static func parts(of url: URL) -> [String: String]? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-v", url.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var parts: [String: String] = [:]
        // "  Length  Method Size Cmpr Date Time CRC-32 Name": the CRC is the 7th column, the name the rest of the line.
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let columns = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard columns.count == 8, Int(columns[0]) != nil, columns[6].count == 8, !columns[7].hasSuffix("/") else { continue }
            parts[columns[7].trimmingCharacters(in: .whitespaces)] = String(columns[6])
        }
        return parts
    }

    /// Throws unless every part outside `edited` (and `removed`, which may be gone) is present and unchanged, and no new
    /// part appeared.
    static func verify(source: URL, output: URL, edited: Set<String>, removed: Set<String> = []) throws {
        guard let before = parts(of: source), let after = parts(of: output) else { throw Failure.unreadable }
        var changed: [String] = []
        for (name, crc) in before where !edited.contains(name) && !removed.contains(name) && after[name] != crc { changed.append(name) }
        for name in after.keys where before[name] == nil { changed.append(name) }
        guard changed.isEmpty else { throw Failure.changed(changed.sorted()) }
    }
}
