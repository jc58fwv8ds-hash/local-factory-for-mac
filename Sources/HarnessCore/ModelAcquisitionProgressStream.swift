import Foundation

/// Parses complete terminal records, not arbitrary transport chunks.
actor ModelAcquisitionProgressStream {
    private var pending: [UInt8] = []
    private var discardingOversizedRecord = false
    private let maximumRecordBytes = 16_384

    func append(_ text: String) -> [ModelAcquisitionProgress] {
        var results: [ModelAcquisitionProgress] = []
        for byte in text.utf8 {
            if byte == 10 || byte == 13 {
                if let progress = flush() { results.append(progress) }
            } else if !discardingOversizedRecord {
                if pending.count == maximumRecordBytes {
                    pending.removeAll(keepingCapacity: true)
                    discardingOversizedRecord = true
                } else {
                    pending.append(byte)
                }
            }
        }
        return results
    }

    func finish() -> ModelAcquisitionProgress? { flush() }

    private func flush() -> ModelAcquisitionProgress? {
        defer {
            pending.removeAll(keepingCapacity: true)
            discardingOversizedRecord = false
        }
        guard !discardingOversizedRecord, !pending.isEmpty else { return nil }
        return ModelAcquisitionProgressParser.parse(String(decoding: pending, as: UTF8.self))
    }
}
