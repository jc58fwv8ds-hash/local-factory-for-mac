import Foundation

public struct SourceChangeSummary: Equatable, Sendable {
    public let addedCount: Int
    public let modifiedCount: Int
    public let removedCount: Int
    public let fileCountDelta: Int
    public let byteDelta: Int64
    public let samplePaths: [String]
    public let hasDetailedChanges: Bool

    public init(
        addedCount: Int,
        modifiedCount: Int,
        removedCount: Int,
        fileCountDelta: Int,
        byteDelta: Int64,
        samplePaths: [String],
        hasDetailedChanges: Bool
    ) {
        self.addedCount = addedCount
        self.modifiedCount = modifiedCount
        self.removedCount = removedCount
        self.fileCountDelta = fileCountDelta
        self.byteDelta = byteDelta
        self.samplePaths = Array(samplePaths.prefix(8))
        self.hasDetailedChanges = hasDetailedChanges
    }

    public var summaryText: String {
        if hasDetailedChanges {
            return "追加 \(addedCount)・変更 \(modifiedCount)・削除 \(removedCount)"
        }
        let fileDeltaText = fileCountDelta == 0
            ? "ファイル数は同じ"
            : "ファイル数 \(fileCountDelta > 0 ? "+" : "")\(fileCountDelta)"
        return "前回確認から内容が変わりました（\(fileDeltaText)）"
    }
}

public struct SourceMonitoringResult: Equatable, Sendable {
    public let inspection: SourceInspection
    public let change: SourceChangeSummary?

    public init(inspection: SourceInspection, change: SourceChangeSummary?) {
        self.inspection = inspection
        self.change = change
    }
}

public actor ProjectSourceMonitor {
    private let scanner: ProjectSourceScanner
    private var snapshots: [String: SourceSnapshot] = [:]

    public init(maxEntries: Int = 2_500) {
        self.scanner = ProjectSourceScanner(maxEntries: maxEntries)
    }

    public func inspect(
        path: String,
        previousInspection: SourceInspection?,
        detectsChanges: Bool = true
    ) async -> SourceMonitoringResult {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        let scan = await scanner.scan(path: key)
        let previousSnapshot = snapshots[key]
        if let snapshot = scan.snapshot {
            snapshots[key] = snapshot
        } else {
            snapshots.removeValue(forKey: key)
        }

        guard detectsChanges else {
            return SourceMonitoringResult(inspection: scan.inspection, change: nil)
        }
        let change = changeSummary(
            previousInspection: previousInspection,
            currentInspection: scan.inspection,
            previousSnapshot: previousSnapshot,
            currentSnapshot: scan.snapshot
        )
        return SourceMonitoringResult(inspection: scan.inspection, change: change)
    }

    public func forget(path: String) {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        snapshots.removeValue(forKey: key)
    }

    private func changeSummary(
        previousInspection: SourceInspection?,
        currentInspection: SourceInspection,
        previousSnapshot: SourceSnapshot?,
        currentSnapshot: SourceSnapshot?
    ) -> SourceChangeSummary? {
        guard let currentSnapshot else { return nil }
        if let previousSnapshot {
            return detailedChange(
                from: previousSnapshot,
                to: currentSnapshot,
                previousInspection: previousInspection,
                currentInspection: currentInspection
            )
        }
        guard let previousInspection,
              let oldRevision = previousInspection.revision,
              let newRevision = currentInspection.revision,
              oldRevision != newRevision else { return nil }
        return SourceChangeSummary(
            addedCount: 0,
            modifiedCount: 0,
            removedCount: 0,
            fileCountDelta: currentInspection.fileCount - previousInspection.fileCount,
            byteDelta: currentInspection.totalBytes - previousInspection.totalBytes,
            samplePaths: [],
            hasDetailedChanges: false
        )
    }

    private func detailedChange(
        from previous: SourceSnapshot,
        to current: SourceSnapshot,
        previousInspection: SourceInspection?,
        currentInspection: SourceInspection
    ) -> SourceChangeSummary? {
        let previousPaths = Set(previous.entries.keys)
        let currentPaths = Set(current.entries.keys)
        let added = currentPaths.subtracting(previousPaths).sorted()
        let removed = previousPaths.subtracting(currentPaths).sorted()
        let modified = previousPaths.intersection(currentPaths)
            .filter { previous.entries[$0] != current.entries[$0] }
            .sorted()
        guard !added.isEmpty || !removed.isEmpty || !modified.isEmpty else { return nil }
        return SourceChangeSummary(
            addedCount: added.count,
            modifiedCount: modified.count,
            removedCount: removed.count,
            fileCountDelta: currentInspection.fileCount - (previousInspection?.fileCount ?? 0),
            byteDelta: currentInspection.totalBytes - (previousInspection?.totalBytes ?? 0),
            samplePaths: added + modified + removed,
            hasDetailedChanges: true
        )
    }
}

struct ProjectSourceScan: Sendable {
    let inspection: SourceInspection
    let snapshot: SourceSnapshot?

    init(inspection: SourceInspection, snapshot: SourceSnapshot? = nil) {
        self.inspection = inspection
        self.snapshot = snapshot
    }
}

struct SourceSnapshot: Sendable {
    let entries: [String: SourceSnapshotEntry]
    let revision: String

    init(entries: [SourceSnapshotEntry]) {
        var uniqueEntries: [String: SourceSnapshotEntry] = [:]
        for entry in entries {
            uniqueEntries[entry.relativePath] = entry
        }
        self.entries = uniqueEntries
        self.revision = SourceRevision.make(entries: Array(uniqueEntries.values))
    }
}

struct SourceSnapshotEntry: Equatable, Sendable {
    let relativePath: String
    let isDirectory: Bool
    let size: Int64
    let modificationMilliseconds: Int64
}

private enum SourceRevision {
    static func make(entries: [SourceSnapshotEntry]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            update(&hash, bytes: entry.relativePath.utf8)
            update(&hash, bytes: [entry.isDirectory ? 1 : 0])
            update(&hash, value: entry.size)
            update(&hash, value: entry.modificationMilliseconds)
        }
        return String(format: "%016llx", hash)
    }

    private static func update<Bytes: Sequence>(_ hash: inout UInt64, bytes: Bytes)
    where Bytes.Element == UInt8 {
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        hash ^= 0xff
        hash &*= 1_099_511_628_211
    }

    private static func update(_ hash: inout UInt64, value: Int64) {
        withUnsafeBytes(of: value.littleEndian) { update(&hash, bytes: $0) }
    }
}
