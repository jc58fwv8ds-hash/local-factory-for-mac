import Foundation

/// Reads only the retained tail, never the complete command log.
struct CommandOutputTail {
    let text: String
    let wasTruncated: Bool

    init(file: URL, maximumBytes: Int) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let retained = min(size, UInt64(max(1, maximumBytes)))
        wasTruncated = size > retained
        try handle.seek(toOffset: size - retained)
        var bytes = Data()
        var remaining = Int(retained)
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: min(8_192, remaining)), !chunk.isEmpty else {
                // A disappearing/truncated log is not an empty successful report.
                throw CocoaError(.fileReadCorruptFile)
            }
            bytes.append(chunk)
            remaining -= chunk.count
        }
        // A byte limit may split a Japanese character. Drop only its incomplete prefix.
        if wasTruncated {
            while let first = bytes.first, first & 0xC0 == 0x80 {
                bytes.removeFirst()
            }
        }
        let tail = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // The error lines of the dropped head are kept before the tail (2026-11-12: a build log's tail held only 「Testing
        // failed… (3 failures)」, the errors were cut off, and the run could not tell what to fix).
        let errors = wasTruncated ? Self.errorLines(file: file, before: size - retained) : []
        text = errors.isEmpty ? tail : (["(前の部分のエラー)"] + errors + ["(ここから最後の部分)", tail]).joined(separator: "\n")
    }

    /// Up to 40 compiler error and failed-test lines (「…: error: …」, 「✘ Test …」) in the first `limit` bytes of the file, without repeats.
    static func errorLines(file: URL, before limit: UInt64) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        var found: [String] = [], seen = Set<String>(), carry = Data(), read: UInt64 = 0, valuesLeft = 0
        let end = min(limit, 32 * 1_024 * 1_024)   // a build log's errors come early; a huge log is not read whole
        while read < end, found.count < 60, let chunk = try? handle.read(upToCount: Int(min(65_536, end - read))), !chunk.isEmpty {
            read += UInt64(chunk.count)
            if carry.count > 65_536 { carry.removeAll() }   // no line is that long; nothing to keep
            guard chunk.contains(10) || carry.count + chunk.count <= 65_536 else { continue }
            carry.append(chunk)
            var lines = String(decoding: carry, as: UTF8.self).components(separatedBy: "\n")
            let last = lines.removeLast()
            carry = Data(last.utf8)
            // Test failures too (2026-11-12: a model's log pushed 「✘ Test … recorded an issue」 out of the tail).
            for line in lines {
                let kept = line.contains(": error:") || line.contains(": fatal error:") || line.contains("✘ Test")
                    || line.contains("Expectation failed") || line.contains("recorded an issue")
                // The values Swift Testing prints under a failed expectation (「↳ result → "さんほん"」).
                let value = valuesLeft > 0 && line.contains("↳")
                valuesLeft = kept ? 3 : (value ? valuesLeft - 1 : 0)
                guard kept || value else { continue }
                let trimmed = String(line.trimmingCharacters(in: .whitespaces).prefix(600))
                if value || seen.insert(trimmed).inserted { found.append(trimmed) }
                if found.count >= 60 { break }
            }
        }
        return found
    }
}
