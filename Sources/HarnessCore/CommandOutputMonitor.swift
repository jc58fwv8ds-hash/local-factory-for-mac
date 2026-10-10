import Foundation

/// Best-effort progress stream; the final result is read independently.
actor CommandOutputMonitor {
    private let file: URL
    private var finalOffset: UInt64?

    init(file: URL) { self.file = file }

    func finish() throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        finalOffset = try handle.seekToEnd()
    }

    func run(observer: @escaping @Sendable (String) async -> Void) async {
        guard !Task.isCancelled, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        var offset: UInt64 = 0
        var decoder = CommandUTF8Decoder()
        while !Task.isCancelled {
            let count: Int
            if let finalOffset {
                guard offset < finalOffset else { break }
                count = Int(min(8_192, finalOffset - offset))
            } else {
                count = 8_192
            }
            let data: Data
            do { data = try handle.read(upToCount: count) ?? Data() }
            catch { return }
            if !data.isEmpty {
                offset += UInt64(data.count)
                guard !Task.isCancelled else { return }
                let text = decoder.append(data)
                if !text.isEmpty { await observer(text) }
            } else {
                guard finalOffset == nil else { break }
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch { return }
            }
        }
        guard !Task.isCancelled else { return }
        let tail = decoder.finish()
        if !tail.isEmpty { await observer(tail) }
    }
}
