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
        text = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
