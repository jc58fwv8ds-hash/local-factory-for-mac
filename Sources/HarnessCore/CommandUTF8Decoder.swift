import Foundation

/// Retains at most three bytes belonging to an unfinished UTF-8 scalar.
struct CommandUTF8Decoder {
    private var pending: [UInt8] = []

    mutating func append(_ data: Data) -> String {
        let bytes = pending + data
        var end = bytes.count
        if !bytes.isEmpty {
            var start = bytes.count - 1
            while start > 0, bytes[start] & 0xC0 == 0x80, bytes.count - start < 4 {
                start -= 1
            }
            let lead = bytes[start]
            let expected = (0xC2...0xDF).contains(lead) ? 2
                : (0xE0...0xEF).contains(lead) ? 3
                : (0xF0...0xF4).contains(lead) ? 4 : 1
            if bytes.count - start < expected { end = start }
        }
        pending = Array(bytes[end...])
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}
